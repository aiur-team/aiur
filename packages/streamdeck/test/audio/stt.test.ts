import { describe, expect, it, vi } from "vitest";
import { createUnavailableTranscriber } from "../../src/audio/stt.js";

describe("unavailable transcriber", () => {
  it("carries a printable reason instead of failing to construct", () => {
    const transcriber = createUnavailableTranscriber("no key configured");
    expect(transcriber.available).toBe(false);
    expect(transcriber.unavailableReason).toBe("no key configured");
  });

  it("reports the reason on open and never emits a transcript", () => {
    const transcriber = createUnavailableTranscriber("no key configured");
    const onError = vi.fn();
    const onTranscript = vi.fn();

    transcriber.open({ onTranscript, onError });

    expect(onError).toHaveBeenCalledWith("no key configured");
    expect(onTranscript).not.toHaveBeenCalled();
  });

  it("returns a session whose push and close are safe to call", () => {
    const transcriber = createUnavailableTranscriber("no key configured");
    const session = transcriber.open({ onTranscript: vi.fn(), onError: vi.fn() });

    // The caller must not have to branch on availability before pushing audio;
    // the no-op session is what keeps the capture path uniform.
    expect(() => {
      session.push(new Uint8Array([1, 2, 3, 4]));
      session.close();
      session.close();
    }).not.toThrow();
  });
});
