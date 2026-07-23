#!/usr/bin/swift

import CoreML
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: compile-tone-coreml.swift INPUT.mlpackage OUTPUT.mlmodelc\n".utf8))
    exit(64)
}

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let staging = destination.deletingLastPathComponent()
    .appending(path: ".\(destination.lastPathComponent).building", directoryHint: .isDirectory)

let compiled = try MLModel.compileModel(at: source)
try? fileManager.removeItem(at: staging)
try fileManager.copyItem(at: compiled, to: staging)
try? fileManager.removeItem(at: destination)
try fileManager.moveItem(at: staging, to: destination)
print(destination.path)
