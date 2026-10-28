import { expect, it } from "vitest";
import { TEXT, MUTED } from "../../src/art/segmentStyle.js";
import { render } from "./renderSegment.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";

it("paints unknown counts as a dash and dims stale counts", () => {
  const summary: SegmentContent = { kind: "summary", model: { live: null, remaining: null, build: null, counts_status: "unavailable" } };
  const unknown = render(summary);
  expect(unknown.ink.find(({ text }) => text === "—")).toBeDefined();
  expect(unknown.ink.some(({ text }) => text === "0")).toBe(false);
  const fresh = render({ ...summary, model: { ...summary.model, live: 2, counts_status: "ok" } });
  const stale = render({ ...summary, model: { ...summary.model, live: 2, counts_status: "stale" } });
  expect(fresh.ink.find(({ text }) => text === "2")?.fill).toBe(TEXT);
  expect(stale.ink.find(({ text }) => text === "2")?.fill).toBe(MUTED);
  expect(stale.pixels).not.toEqual(fresh.pixels);
});

it("fits the default pager label in 200 pixels and dims stale labels", () => {
  const pager: SegmentContent = { kind: "pager", title: "MORE AGENTS", label: "14 agents · 512 queued", stale: true,
    model: { windowCount: 1, currentWindow: 0, dots: [true], hasMultiple: false } };
  const { ink } = render(pager);
  expect(ink[0]?.text).toBe("14 agents · 512 queued");
  expect(ink[0]?.x).toBeGreaterThanOrEqual(0);
  expect(ink[0]?.fill).toBe(MUTED);
});
