import { describe, expect, it } from "vitest";

import { type AgentInput, type AgentKey, layoutKeys } from "../../src/keys.js";
import {
  type AgentKeyFace,
  DEFAULT_TITLE_LINE_CHARS,
  composeKeyFace,
  wrapTitle,
} from "../../src/keys/keyFace.js";

const descriptorFor = (input: Partial<AgentInput> & Pick<AgentInput, "bucket">): AgentKey => {
  const agent: AgentInput = {
    identifier: input.identifier ?? "1355",
    vendor: input.vendor ?? "claude",
    bucket: input.bucket,
    progress_percent: input.progress_percent ?? 40,
    priority: input.priority ?? false,
    title: input.title,
    dependency_ready: input.dependency_ready,
  };
  const key = layoutKeys([agent], 0)[0];
  if (key.kind !== "agent") throw new Error("expected agent key");
  return key;
};

describe("wrapTitle", () => {
  it("returns two empty lines for blank input", () => {
    expect(wrapTitle("   ")).toEqual(["", ""]);
  });

  it("keeps short titles on the first line", () => {
    expect(wrapTitle("hello", 9)).toEqual(["hello", ""]);
  });

  it("flows onto the second line when the first is full", () => {
    expect(wrapTitle("aaaaa bbbbb", 5)).toEqual(["aaaaa", "bbbbb"]);
  });

  it("truncates overflow past the second line with an ellipsis", () => {
    expect(wrapTitle("aaaaa bbbbb ccccc", 5)).toEqual(["aaaaa", "bbbb…"]);
  });

  it("hard-splits a word longer than the line budget", () => {
    expect(wrapTitle("abcdef", 3)).toEqual(["abc", "def"]);
  });

  it("clamps a non-positive budget to one character", () => {
    expect(wrapTitle("ab", 0)).toEqual(["a", "b"]);
  });

  it("defaults the line budget", () => {
    expect(DEFAULT_TITLE_LINE_CHARS).toBe(9);
    expect(wrapTitle("abcdefghijkl")).toEqual(["abcdefghi", "jkl"]);
  });
});

describe("composeKeyFace", () => {
  it("composes an empty descriptor as a black fill", () => {
    expect(composeKeyFace({ kind: "empty" })).toEqual({ kind: "empty", fill: { r: 0, g: 0, b: 0 } });
  });

  it("carries bucket style, vendor, ticket, title, priority and footer", () => {
    const face = composeKeyFace(
      descriptorFor({ bucket: "running", identifier: "1355", title: "Stream Deck", priority: true }),
    ) as AgentKeyFace;
    expect(face.kind).toBe("agent");
    expect(face.vendor).toBe("claude");
    expect(face.ticketNumber).toBe("1355");
    expect(face.priority).toBe(true);
    expect(face.titleLines).toEqual(["Stream", "Deck"]);
    expect(face.pulseSeconds).toBeNull(); // running does not pulse
    expect(face.footer.kind).toBe("progress");
  });

  it("exposes the pulse period for pulsing buckets", () => {
    const face = composeKeyFace(descriptorFor({ bucket: "stuck" })) as AgentKeyFace;
    expect(face.pulseSeconds).toBe(1.4);
  });

  it("carries a queued footer", () => {
    const face = composeKeyFace(descriptorFor({ bucket: "queued", dependency_ready: false })) as AgentKeyFace;
    expect(face.footer).toMatchObject({ kind: "queued", unblocked: false });
  });

  it("uses an empty string for a missing title", () => {
    const face = composeKeyFace(descriptorFor({ bucket: "running", title: null })) as AgentKeyFace;
    expect(face.titleLines).toEqual(["", ""]);
  });
});
