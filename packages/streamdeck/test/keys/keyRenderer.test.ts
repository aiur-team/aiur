import { describe, expect, it } from "vitest";

import { type KeyDescriptor } from "../../src/keys.js";
import { KeyCache, type KeyPaint } from "../../src/keys/keyCache.js";
import { type KeyContent } from "../../src/keys/keyContent.js";
import { type KeyEncoder, KeyRenderer } from "../../src/keys/keyRenderer.js";
import { agentKey } from "./descriptorFixtures.js";

// Encoder: empty keys -> black fill; agent keys -> a JPEG derived from the
// descriptor so identical descriptors yield identical bytes (deterministic).
const encoder: KeyEncoder = (descriptor: KeyDescriptor): KeyContent => {
  if (descriptor.kind === "empty") return { kind: "fill", color: { r: 0, g: 0, b: 0 } };
  const seed = `${descriptor.identifier}:${descriptor.progressPercent}`;
  return { kind: "image", jpeg: new Uint8Array([...seed].map((c) => c.charCodeAt(0) & 0xff)) };
};

// Model a successful write of every returned paint: only then does the cache
// commit, mirroring the write-queue contract (commit after the transfer lands).
const commitAll = (paints: readonly KeyPaint[]): void => {
  for (const paint of paints) paint.commit();
};

const panel = (mutate?: (keys: KeyDescriptor[]) => void): KeyDescriptor[] => {
  const keys: KeyDescriptor[] = Array.from({ length: 8 }, (_, i) =>
    agentKey({ identifier: String(i), progressPercent: 10 }),
  );
  mutate?.(keys);
  return keys;
};

describe("KeyRenderer", () => {
  it("renders all eight keys on the first render", () => {
    const renderer = new KeyRenderer(encoder);
    const paints = renderer.render(panel());
    expect(paints.map((p) => p.index)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it("repaints exactly one key when one agent's state ticks", () => {
    const renderer = new KeyRenderer(encoder);
    commitAll(renderer.render(panel()));

    const after = panel((keys) => {
      keys[4] = agentKey({ identifier: "4", progressPercent: 55 });
    });
    const paints = renderer.render(after);
    expect(paints.map((p) => p.index)).toEqual([4]);
  });

  it("does not commit until the write path commits the paint", () => {
    const renderer = new KeyRenderer(encoder);
    // First render returns paints but we do NOT commit (a failed write): the
    // cache stays dirty, so a re-render still asks to repaint every key.
    renderer.render(panel());
    expect(renderer.render(panel()).map((p) => p.index)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
  });

  it("re-rendering identical descriptors produces no writes once committed", () => {
    const renderer = new KeyRenderer(encoder);
    commitAll(renderer.render(panel()));
    expect(renderer.render(panel())).toEqual([]);
  });

  it("invalidate forces a repaint of the affected key", () => {
    const renderer = new KeyRenderer(encoder);
    commitAll(renderer.render(panel()));
    renderer.invalidate(0);
    expect(renderer.render(panel()).map((p) => p.index)).toEqual([0]);
  });

  it("accepts an injected cache", () => {
    const cache = new KeyCache();
    const renderer = new KeyRenderer(encoder, cache);
    const keys = panel();
    commitAll(renderer.render(keys));
    // The shared cache already has key 0 clean.
    expect(cache.isDirty(0, encoder(keys[0], 0))).toBe(false);
  });

  it("rejects a descriptor list that is not exactly eight keys", () => {
    const renderer = new KeyRenderer(encoder);
    expect(() => renderer.render([])).toThrow(RangeError);
  });
});
