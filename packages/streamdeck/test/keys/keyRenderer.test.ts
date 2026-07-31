import { describe, expect, it } from "vitest";

import { type AgentInput, type KeyDescriptor, layoutKeys } from "../../src/keys.js";
import { KeyCache } from "../../src/keys/keyCache.js";
import { type KeyContent } from "../../src/keys/keyContent.js";
import { type KeyEncoder, KeyRenderer } from "../../src/keys/keyRenderer.js";

const agent = (identifier: string, progress: number): AgentInput => ({
  identifier,
  vendor: "claude",
  bucket: "running",
  progress_percent: progress,
  priority: false,
});

// Encoder: empty keys -> black fill; agent keys -> a JPEG derived from the
// descriptor so identical descriptors yield identical bytes (deterministic).
const encoder: KeyEncoder = (descriptor: KeyDescriptor): KeyContent => {
  if (descriptor.kind === "empty") return { kind: "fill", color: { r: 0, g: 0, b: 0 } };
  const seed = `${descriptor.identifier}:${descriptor.progressPercent}`;
  return { kind: "image", jpeg: new Uint8Array([...seed].map((c) => c.charCodeAt(0) & 0xff)) };
};

describe("KeyRenderer", () => {
  it("renders all eight keys on the first render", () => {
    const renderer = new KeyRenderer(encoder);
    const descriptors = layoutKeys([agent("100", 10), agent("101", 20)], 0);
    const paints = renderer.render(descriptors);
    expect(paints.map((p) => p.index)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it("repaints exactly one key when one agent's state ticks", () => {
    const renderer = new KeyRenderer(encoder);
    const before = layoutKeys([agent("100", 10), agent("101", 20)], 0);
    renderer.render(before);

    const after = layoutKeys([agent("100", 10), agent("101", 55)], 0);
    const paints = renderer.render(after);
    // Column-major: agents[1] occupies (col 0, row 1) -> key index 4.
    expect(paints.map((p) => p.index)).toEqual([4]);
  });

  it("re-rendering identical descriptors produces no writes", () => {
    const renderer = new KeyRenderer(encoder);
    const descriptors = layoutKeys([agent("100", 10)], 0);
    renderer.render(descriptors);
    expect(renderer.render(descriptors)).toEqual([]);
  });

  it("invalidate forces a repaint of the affected key", () => {
    const renderer = new KeyRenderer(encoder);
    const descriptors = layoutKeys([agent("100", 10)], 0);
    renderer.render(descriptors);
    renderer.invalidate(0);
    expect(renderer.render(descriptors).map((p) => p.index)).toEqual([0]);
  });

  it("accepts an injected cache", () => {
    const cache = new KeyCache();
    const renderer = new KeyRenderer(encoder, cache);
    const descriptors = layoutKeys([agent("100", 10)], 0);
    renderer.render(descriptors);
    // The shared cache already has key 0 clean.
    expect(cache.isDirty(0, encoder(descriptors[0], 0))).toBe(false);
  });

  it("rejects a descriptor list that is not exactly eight keys", () => {
    const renderer = new KeyRenderer(encoder);
    expect(() => renderer.render([])).toThrow(RangeError);
  });
});
