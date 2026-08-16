import { describe, expect, it } from "vitest";
import { createUnavailableTTSProvider } from "../../src/audio/tts.js";

describe("createUnavailableTTSProvider", () => {
  it("reports unavailable with a printable reason", () => {
    const provider = createUnavailableTTSProvider("no key");
    expect(provider.available).toBe(false);
    expect(provider.unavailableReason).toBe("no key");
  });

  it("throws the reason when asked to synthesize", async () => {
    const provider = createUnavailableTTSProvider("no key");
    const iterator = provider.synthesizeStream({ requestId: "r", text: "hi", voiceId: "v" })[Symbol.asyncIterator]();
    await expect(iterator.next()).rejects.toThrow("no key");
  });
});
