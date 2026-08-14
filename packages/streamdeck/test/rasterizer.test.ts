import { createCanvas, loadImage } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { createRasterizer, wrapToWidth } from "../src/rasterizer.js";
import { layoutKeys, type AgentInput } from "../src/keys.js";

const agent = (overrides: Partial<AgentInput> = {}): AgentInput => ({
  identifier: "1437",
  title: "Solo operator onboarding flow",
  vendor: "claude",
  icon: "flow",
  bucket: "running",
  progress_percent: 62,
  priority: false,
  dependency_ready: true,
  ...overrides,
});

/** Fraction of pixels that are not near-black, i.e. how much was painted. */
const inkFraction = async (jpeg: Uint8Array): Promise<number> => {
  const canvas = createCanvas(120, 120);
  const context = canvas.getContext("2d");
  context.drawImage(await loadImage(Buffer.from(jpeg)), 0, 0);
  const { data } = context.getImageData(0, 0, 120, 120);
  let inked = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] > 30 || data[i + 1] > 30 || data[i + 2] > 30) inked += 1;
  }
  return inked / (120 * 120);
};

describe("wrapToWidth", () => {
  const context = createCanvas(120, 120).getContext("2d");
  context.font = "600 14px sans-serif";
  const width = 102;

  it("keeps a short title on one line", () => {
    expect(wrapToWidth(context, "V2 webhooks", width, 3)).toEqual(["V2 webhooks"]);
  });

  it("wraps on word boundaries without splitting words that fit", () => {
    const lines = wrapToWidth(context, "Orchestrator wake on cleared deps", width, 3);
    expect(lines.length).toBeLessThanOrEqual(3);
    expect(lines[0]).toBe("Orchestrator");
  });

  // Dropping the overflow silently is what made long titles look like they had
  // simply been truncated at an arbitrary point.
  it("marks a title that overflows the last line with an ellipsis", () => {
    const lines = wrapToWidth(context, "Restore retry statistics across the whole fleet dashboard", width, 2);
    expect(lines).toHaveLength(2);
    expect(lines[1].endsWith("…")).toBe(true);
  });

  it("hard-splits a single word wider than the line", () => {
    const lines = wrapToWidth(context, "Supercalifragilisticexpialidocious", width, 3);
    expect(lines.length).toBeGreaterThan(1);
    for (const line of lines) {
      expect(context.measureText(line.replace("…", "")).width).toBeLessThanOrEqual(width);
    }
  });

  it("never exceeds the requested line count", () => {
    const lines = wrapToWidth(context, "one two three four five six seven eight nine ten", width, 3);
    expect(lines.length).toBeLessThanOrEqual(3);
  });
});

describe("createRasterizer key", () => {
  // A CSS gradient assigned straight to fillStyle is ignored by canvas, which
  // left every key a black rectangle on the device even though the contract
  // specified a colour.
  it("paints the bucket colours rather than leaving the key black", async () => {
    const [descriptor] = layoutKeys([agent()], 0);
    expect(await inkFraction(createRasterizer().key(descriptor))).toBeGreaterThan(0.2);
  });

  it("renders a distinct image per bucket", () => {
    const rasterizer = createRasterizer();
    const running = rasterizer.key(layoutKeys([agent({ bucket: "running" })], 0)[0]);
    const stuck = rasterizer.key(layoutKeys([agent({ bucket: "stuck" })], 0)[0]);
    expect(Buffer.from(running).equals(Buffer.from(stuck))).toBe(false);
  });

  it("renders a distinct image when only progress changes", () => {
    const rasterizer = createRasterizer();
    const low = rasterizer.key(layoutKeys([agent({ progress_percent: 10 })], 0)[0]);
    const high = rasterizer.key(layoutKeys([agent({ progress_percent: 90 })], 0)[0]);
    expect(Buffer.from(low).equals(Buffer.from(high))).toBe(false);
  });

  it("is deterministic, so the render cache can treat a key as clean", () => {
    const rasterizer = createRasterizer();
    const descriptor = layoutKeys([agent()], 0)[0];
    expect(Buffer.from(rasterizer.key(descriptor)).equals(Buffer.from(rasterizer.key(descriptor)))).toBe(true);
  });

  it("distinguishes a blocked queued key from an unblocked one", () => {
    const rasterizer = createRasterizer();
    const ready = rasterizer.key(layoutKeys([agent({ bucket: "queued", dependency_ready: true })], 0)[0]);
    const blocked = rasterizer.key(layoutKeys([agent({ bucket: "queued", dependency_ready: false })], 0)[0]);
    expect(Buffer.from(ready).equals(Buffer.from(blocked))).toBe(false);
  });

  // The mock marks a prioritised ticket with a gold star. It is omitted by
  // operator request — on a 120px key it read as an unexplained decoration —
  // so priority must not change the painted key at all.
  it("does not mark a prioritised agent on the key face", () => {
    const rasterizer = createRasterizer();
    const plain = rasterizer.key(layoutKeys([agent({ priority: false })], 0)[0]);
    const prioritised = rasterizer.key(layoutKeys([agent({ priority: true })], 0)[0]);
    expect(Buffer.from(plain).equals(Buffer.from(prioritised))).toBe(true);
  });

  it("paints an empty key as a flat blackout", async () => {
    const rasterizer = createRasterizer();
    expect(await inkFraction(rasterizer.key(layoutKeys([], 0)[0]))).toBeLessThan(0.02);
  });

  // The strip and the keys are tied both ways: pressing an event key scrolls
  // the strip to it, and scrolling the strip highlights the key. The highlight
  // is the only thing on the deck that shows the two agree, so it has to reach
  // actual pixels.
  it("paints a selected event key differently from an unselected one", () => {
    const rasterizer = createRasterizer();
    const event = (selected: boolean): AgentInput =>
      agent({ role: "event", subLabel: "EMIT", timeLabel: "3m", title: "Dependency cleared", selected });
    const plain = rasterizer.key(layoutKeys([event(false)], 0)[0]);
    const highlighted = rasterizer.key(layoutKeys([event(true)], 0)[0]);
    expect(Buffer.from(plain).equals(Buffer.from(highlighted))).toBe(false);
  });

  // LIVE is a jump to the newest entry, not an event, so it is never the key
  // the strip is reading and must not react to the flag.
  it("does not highlight the LIVE key", () => {
    const rasterizer = createRasterizer();
    const live = (selected: boolean): AgentInput => agent({ role: "live", title: "LIVE", selected });
    expect(Buffer.from(rasterizer.key(layoutKeys([live(false)], 0)[0])).equals(Buffer.from(rasterizer.key(layoutKeys([live(true)], 0)[0])))).toBe(true);
  });
});

describe("rasterizer.segment", () => {
  const blank = { kind: "blank" } as const;

  it("encodes a panel at the width it was asked for", async () => {
    const rasterizer = createRasterizer();
    for (const width of [200, 400, 800]) {
      const image = await loadImage(Buffer.from(rasterizer.segment(blank, width)));
      expect(image.width).toBe(width);
      expect(image.height).toBe(100);
    }
  });

  it("defaults to one 200-wide segment", async () => {
    expect((await loadImage(Buffer.from(createRasterizer().segment(blank)))).width).toBe(200);
  });

  // Serving a cached 200-wide image for the 400-wide merged provider area would
  // upload a JPEG that does not cover the region it was written to.
  it("does not serve one width's image for another", () => {
    const rasterizer = createRasterizer();
    const narrow = rasterizer.segment(blank, 200);
    expect(Buffer.from(narrow).equals(Buffer.from(rasterizer.segment(blank, 400)))).toBe(false);
    expect(Buffer.from(narrow).equals(Buffer.from(rasterizer.segment(blank, 200)))).toBe(true);
  });

  // The strip's content is now unbounded — one distinct panel per scroll
  // position of every transcript — so the cache has to evict rather than grow
  // for the life of the process.
  it("stays serviceable past its cache limit", () => {
    const rasterizer = createRasterizer();
    for (let width = 40; width < 800; width += 1) rasterizer.segment(blank, width);
    expect(rasterizer.segment(blank, 200).length).toBeGreaterThan(0);
  });
});
