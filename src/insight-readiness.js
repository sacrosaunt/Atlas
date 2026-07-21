function waitForPoll(signal, pollMs) {
  return new Promise((resolve, reject) => {
    const abort = () => {
      clearTimeout(timer);
      reject(new DOMException("Insight preparation cancelled", "AbortError"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", abort);
      resolve();
    }, pollMs);
    if (signal?.aborted) abort();
    else signal?.addEventListener("abort", abort, { once: true });
  });
}

export async function waitForInitialInsightInputs({
  semanticIndex,
  sentimentIndex,
  signal,
  pollMs = 1_000,
} = {}) {
  while (true) {
    if (signal?.aborted) throw new DOMException("Insight preparation cancelled", "AbortError");
    const semantic = semanticIndex.status();
    const sentiment = sentimentIndex.status();
    const textSettled = ["ready", "error"].includes(semantic.text_index_phase);
    const toneSettled = semantic.text_index_phase === "error"
      || ["ready", "error", "off"].includes(sentiment.phase)
      || sentiment.enabled === false;
    if (textSettled && toneSettled) {
      return {
        text_index_phase: semantic.text_index_phase,
        tone_phase: sentiment.phase,
      };
    }
    await waitForPoll(signal, pollMs);
  }
}
