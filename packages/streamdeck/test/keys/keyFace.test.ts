import { describe, expect, it } from "vitest";

import { type AgentKey } from "../../src/keys.js";
import {
  type AgentKeyFace,
  DEFAULT_TITLE_LINE_CHARS,
  composeKeyFace,
  wrapTitle,
} from "../../src/keys/keyFace.js";
import { agentKey } from "./descriptorFixtures.js";

interface DescriptorInput {
  readonly bucket: AgentKey["bucket"];
  readonly identifier?: string;
  readonly title?: string | null;
  readonly vendor?: AgentKey["vendor"];
  readonly progress_percent?: number;
  readonly priority?: boolean;
  readonly dependency_ready?: boolean;
}

const descriptorFor = (input: DescriptorInput): AgentKey =>
  agentKey({
    bucket: input.bucket,
    identifier: input.identifier,
    title: input.title,
    vendor: input.vendor,
    progressPercent: input.progress_percent,
    priority: input.priority,
    dependencyReady: input.dependency_ready,
  });

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
