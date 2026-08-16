import { describe, expect, it } from "vitest";
import { createTranscriptBuffer } from "../../src/audio/buffer.js";

describe("transcript buffer", () => {
  it("starts empty", () => {
    const buffer = createTranscriptBuffer();
    expect(buffer.isEmpty()).toBe(true);
    expect(buffer.display()).toBe("");
    expect(buffer.committed()).toBe("");
  });

  it("revises the partial in place rather than appending it", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "partial", text: "run the" });
    buffer.apply({ kind: "partial", text: "run the tests" });
    expect(buffer.display()).toBe("run the tests");
    // A partial is never sendable: only settled text reaches the agent.
    expect(buffer.committed()).toBe("");
    expect(buffer.isEmpty()).toBe(true);
  });

  it("appends settled text across several holds", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "final", text: "run the tests" });
    buffer.dropPartial();
    buffer.apply({ kind: "final", text: "then open a pull request" });
    expect(buffer.committed()).toBe("run the tests then open a pull request");
    expect(buffer.isEmpty()).toBe(false);
  });

  it("lets a settled frame supersede the partial it revised", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "partial", text: "run the tes" });
    buffer.apply({ kind: "final", text: "run the tests" });
    // Keeping both would print every phrase twice in the panel.
    expect(buffer.display()).toBe("run the tests");
    expect(buffer.committed()).toBe("run the tests");
  });

  it("ignores blank and whitespace-only updates", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "final", text: "" });
    buffer.apply({ kind: "final", text: "   \n\t " });
    expect(buffer.isEmpty()).toBe(true);
    expect(buffer.committed()).toBe("");
  });

  it("trims the surrounding whitespace the provider sends", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "partial", text: "  hello  " });
    expect(buffer.display()).toBe("hello");
  });

  it("joins settled text and the live partial with a single space", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "final", text: "run the tests" });
    buffer.apply({ kind: "partial", text: "and then" });
    expect(buffer.display()).toBe("run the tests and then");
  });

  it("does not introduce a space when either side is empty", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "partial", text: "only a partial" });
    expect(buffer.display()).toBe("only a partial");

    const settledOnly = createTranscriptBuffer();
    settledOnly.apply({ kind: "final", text: "only settled" });
    expect(settledOnly.display()).toBe("only settled");
  });

  it("drops the partial at the end of a hold but keeps settled text", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "final", text: "settled" });
    buffer.apply({ kind: "partial", text: "never finished" });
    buffer.dropPartial();
    expect(buffer.display()).toBe("settled");
    expect(buffer.committed()).toBe("settled");
  });

  it("discards everything on clear", () => {
    const buffer = createTranscriptBuffer();
    buffer.apply({ kind: "final", text: "settled" });
    buffer.apply({ kind: "partial", text: "in flight" });
    buffer.clear();
    expect(buffer.display()).toBe("");
    expect(buffer.committed()).toBe("");
    expect(buffer.isEmpty()).toBe(true);
  });
});
