#!/usr/bin/env python3
"""Convert Atlas's pinned tone classifier into a shared-weight Core ML package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import urllib.request
from pathlib import Path

import coremltools as ct
import coremltools.optimize as cto
import numpy as np
import torch
from transformers import AutoModelForSequenceClassification


MODEL_ID = "cardiffnlp/twitter-roberta-base-sentiment-latest"
MODEL_REVISION = "3216a57f2a0d9c45a2e6c20157c20c49fb4bf9c7"
MODEL_FILES = (
    ("config.json", 929, "d2fba19997da698157196ba16f5fcb30a97a7551cef6845a0f3d743ee19c6129"),
    ("pytorch_model.bin", 501_045_531, "4d24a3e32a88ed1c4e5b789fc6644e2e767500554e954b27dccf52a8e762cbae"),
)
BATCH_SIZE = 8
SEQUENCE_LENGTHS = (32, 64, 128, 256, 512)


class ToneClassifier(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        input_ids = input_ids.to(torch.int64)
        embeddings = self.model.roberta.embeddings(input_ids=input_ids)
        # Hugging Face uses the minimum float32 value here. Core ML correctly
        # converts the network to FP16, but that particular sentinel overflows
        # and measurably changes attention. -10,000 is already effectively zero
        # after softmax and remains finite in both FP32 and FP16.
        extended_mask = (1.0 - attention_mask[:, None, None, :].to(embeddings.dtype)) * -10_000.0
        encoded = self.model.roberta.encoder(
            embeddings,
            attention_mask=extended_mask,
            return_dict=False,
        )[0]
        return self.model.classifier(encoded)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--quantization", choices=("none", "int8"), default="none")
    parser.add_argument("--compute-precision", choices=("float16", "float32"), default="float16")
    parser.add_argument("--sequence-lengths", default=",".join(map(str, SEQUENCE_LENGTHS)))
    parser.add_argument("--progress", type=Path)
    return parser.parse_args()


def report_progress(path: Path | None, phase: str, completed: int, total: int, detail: str) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "phase": phase,
        "completed": completed,
        "total": total,
        "detail": detail,
    }) + "\n")
    os.replace(temporary, path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_model(destination: Path, progress: Path | None) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    total_bytes = sum(size for _, size, _ in MODEL_FILES)
    completed_bytes = 0
    for filename, expected_size, expected_hash in MODEL_FILES:
        target = destination / filename
        if (
            target.is_file()
            and target.stat().st_size == expected_size
            and sha256(target) == expected_hash
        ):
            completed_bytes += expected_size
            continue

        temporary = target.with_suffix(target.suffix + ".download")
        temporary.unlink(missing_ok=True)
        url = f"https://huggingface.co/{MODEL_ID}/resolve/{MODEL_REVISION}/{filename}"
        request = urllib.request.Request(url, headers={"User-Agent": "Atlas-CoreML-Setup/1"})
        digest = hashlib.sha256()
        with urllib.request.urlopen(request) as response, temporary.open("wb") as output:
            file_bytes = 0
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
                file_bytes += len(chunk)
                transferred = completed_bytes + file_bytes
                percent = 10 + int(34 * transferred / total_bytes)
                report_progress(
                    progress,
                    "downloading",
                    percent,
                    100,
                    f"Downloading tone model ({transferred / 1_000_000:.0f} of {total_bytes / 1_000_000:.0f} MB)",
                )
        if file_bytes != expected_size or digest.hexdigest() != expected_hash:
            temporary.unlink(missing_ok=True)
            raise RuntimeError(f"Downloaded {filename} did not match the pinned model")
        os.replace(temporary, target)
        completed_bytes += expected_size


def main() -> None:
    arguments = parse_arguments()
    sequence_lengths = tuple(int(value) for value in arguments.sequence_lengths.split(","))
    if not sequence_lengths or any(value not in SEQUENCE_LENGTHS for value in sequence_lengths):
        raise ValueError(f"Sequence lengths must come from {SEQUENCE_LENGTHS}")
    arguments.cache.mkdir(parents=True, exist_ok=True)
    arguments.output.parent.mkdir(parents=True, exist_ok=True)

    source_directory = arguments.cache / "source"
    report_progress(arguments.progress, "downloading", 10, 100, "Downloading the pinned tone model")
    download_model(source_directory, arguments.progress)
    model = AutoModelForSequenceClassification.from_pretrained(
        source_directory,
        local_files_only=True,
        attn_implementation="eager",
    ).eval()
    report_progress(arguments.progress, "converting", 45, 100, "Preparing the model for Apple silicon")
    wrapped = ToneClassifier(model).eval()
    function_directory = arguments.output.parent / ".tone-coreml-functions"
    if function_directory.exists():
        shutil.rmtree(function_directory)
    function_directory.mkdir(parents=True)
    descriptor = ct.utils.MultiFunctionDescriptor()
    for index, length in enumerate(sequence_lengths):
        report_progress(
            arguments.progress,
            "converting",
            45 + int(index * 45 / len(sequence_lengths)),
            100,
            f"Converting sequence profile {index + 1} of {len(sequence_lengths)}",
        )
        example_ids = torch.zeros((BATCH_SIZE, length), dtype=torch.int32)
        example_mask = torch.ones((BATCH_SIZE, length), dtype=torch.int32)
        with torch.no_grad():
            traced = torch.jit.trace(wrapped, (example_ids, example_mask), strict=False)
        converted_model = ct.convert(
            traced,
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=(
                ct.precision.FLOAT16
                if arguments.compute_precision == "float16"
                else ct.precision.FLOAT32
            ),
            inputs=[
                ct.TensorType(name="input_ids", shape=(BATCH_SIZE, length), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(BATCH_SIZE, length), dtype=np.int32),
            ],
            outputs=[ct.TensorType(name="logits")],
        )
        if arguments.quantization == "int8":
            quantization = cto.coreml.OptimizationConfig(
                global_config=cto.coreml.OpLinearQuantizerConfig(
                    mode="linear_symmetric",
                    dtype="int8",
                    granularity="per_channel",
                    weight_threshold=512,
                )
            )
            converted_model = cto.coreml.linear_quantize_weights(converted_model, quantization)
        function_path = function_directory / f"tone-s{length}.mlpackage"
        converted_model.save(str(function_path))
        descriptor.add_function(str(function_path), "main", f"tone_b{BATCH_SIZE}_s{length}")
    default_length = 128 if 128 in sequence_lengths else sequence_lengths[0]
    descriptor.default_function_name = f"tone_b{BATCH_SIZE}_s{default_length}"
    temporary_output = arguments.output.with_name(f"{arguments.output.stem}.building.mlpackage")
    if temporary_output.exists():
        shutil.rmtree(temporary_output)
    if arguments.output.exists():
        shutil.rmtree(arguments.output)
    ct.utils.save_multifunction(descriptor, str(temporary_output))
    temporary_output.rename(arguments.output)
    shutil.rmtree(function_directory)
    report_progress(arguments.progress, "compiling", 92, 100, "Compiling the model for this Mac")
    print(arguments.output)


if __name__ == "__main__":
    main()
