import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { ageLabel, PROVIDER_SCROLL_BAND_TOP, resetLabel } from "../../src/art/segments.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";
import { PROVIDER_SCROLL_ENCODER, VISIBLE_PROVIDER_ROWS, type ProviderPanelModel, type ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import { encoderCenterX, SEGMENT_WIDTH } from "../../src/touchStrip/geometry.js";
import { BACKGROUND, NOW, render, type Ink } from "./renderSegment.js";
import {
  inkedColumns,
  litColumns,
  drew,
  summary,
  providerRow,
  provider,
  session,
} from "./segmentFixtures.js";

describe("ageLabel", () => {
  const now = Date.parse("2026-08-13T03:00:00Z");
  it("reads a past instant as a compact age", () => {
    expect(ageLabel("2026-08-13T02:59:30Z", now)).toBe("now");
    expect(ageLabel("2026-08-13T02:57:00Z", now)).toBe("3m");
    expect(ageLabel("2026-08-13T01:00:00Z", now)).toBe("2h");
    expect(ageLabel("2026-08-11T03:00:00Z", now)).toBe("2d");
  });

  it("has no label for a missing or unparseable timestamp", () => {
    expect(ageLabel(null, now)).toBeNull();
    expect(ageLabel("whenever", now)).toBeNull();
  });
});

describe("resetLabel", () => {
  it("reads a future instant as a compact countdown", () => {
    expect(resetLabel("2026-08-13T03:22:00Z", NOW)).toBe("22m");
    expect(resetLabel("2026-08-13T04:30:00Z", NOW)).toBe("1h 30m");
    expect(resetLabel("2026-08-15T03:00:00Z", NOW)).toBe("2d");
  });

  // A window whose reset has already passed still arrives from the daemon until
  // the next poll; it must read as "now", not as a negative countdown.
  it("reads an elapsed window as 'now'", () => {
    expect(resetLabel("2026-08-13T02:59:00Z", NOW)).toBe("now");
  });

  it("has no label for a missing or unparseable instant", () => {
    expect(resetLabel(null, NOW)).toBeNull();
    expect(resetLabel("soon", NOW)).toBeNull();
  });
});

describe("summary panel", () => {
  it("paints the live count and the build bar", () => {
    const { ink, inked } = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: "58m" }));
    expect(drew(ink, "Summary")).toBeDefined();
    expect(drew(ink, "7")).toBeDefined();
    expect(drew(ink, "Build 40%")).toBeDefined();
    expect(drew(ink, "ETA 58m")).toBeDefined();
    expect(inked).toBeGreaterThan(0);
  });

  it("omits the ETA when the build order has not projected one", () => {
    const { ink } = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: null }));
    expect(drew(ink, "Build 40%")).toBeDefined();
    expect(ink.some((entry) => entry.text.startsWith("ETA"))).toBe(false);
  });

  // A fleet with no build order must say so rather than show a 0% bar, which
  // reads as a build that has made no progress.
  it("says so when there is no build order, and draws no bar", () => {
    const withBuild = render(summary({ completed: 13, total: 32, fraction: 0.4, etaLabel: "58m" }));
    const without = render(summary(null));
    expect(drew(without.ink, "No build order")).toBeDefined();
    expect(without.ink.some((entry) => entry.text.startsWith("Build"))).toBe(false);
    expect(without.inked).toBeLessThan(withBuild.inked);
  });
});

describe("provider panel (two providers)", () => {
  it("paints the provider name, its session percent and its reset", () => {
    const { ink } = render(provider(session(86, "2026-08-13T03:22:00Z")));
    expect(drew(ink, "Claude")).toBeDefined();
    expect(drew(ink, "Session")).toBeDefined();
    expect(drew(ink, "86% · 22m")).toBeDefined();
  });

  it("shows the percent alone when the window reported no reset", () => {
    expect(drew(render(provider(session(86))).ink, "86%")).toBeDefined();
  });

  // A durable last-known reading (the dashboard's dispatch-limits fallback,
  // #2185) renders its real used% without staleness wording (operator directive).
  it("renders a durable provider reading without staleness text", () => {
    const { ink } = render(provider({ ...session(99), freshness: "stale" }));
    expect(drew(ink, "Session")).toBeDefined();
    expect(drew(ink, "99%")).toBeDefined();
    expect(drew(ink, "stale")).toBeUndefined();
  });

  // "no reading yet" and "zero usage" are different states; rendering both as
  // 0% is the parity bug this panel exists to avoid.
  it("distinguishes a provider with no reading from one at zero", () => {
    const awaiting = render(provider({ hasData: false }));
    expect(drew(awaiting.ink, "Awaiting data")).toBeDefined();
    expect(awaiting.ink.some((entry) => entry.text.includes("0%"))).toBe(false);

    expect(drew(render(provider(session(0))).ink, "0%")).toBeDefined();
  });

  it("says which window is missing when a reporting provider has no session", () => {
    const { ink } = render(provider({ hasData: true, session: null, weekly: { usedPercent: 12, resetsAt: null } }));
    expect(drew(ink, "No session window")).toBeDefined();
  });

  it("draws a lettered token for a provider with no bundled mark", () => {
    expect(render({ kind: "provider", row: providerRow("zephyr", { hasData: false }) }).inked).toBeGreaterThan(0);
  });
});

describe("provider panel (three or more)", () => {
  /** The panel as the layout composes it: the centre two segments, so x=200. */
  const PANEL_X = SEGMENT_WIDTH;

  const wide = (
    rows: readonly ProviderPanelRow[],
    scroll: Partial<Pick<ProviderPanelModel, "total" | "hasAbove" | "hasBelow">> = {},
    originX = PANEL_X,
  ): SegmentContent => ({
    kind: "providers",
    model: { rows, total: rows.length, hasAbove: false, hasBelow: false, ...scroll },
    originX,
  });

  it("paints a row per provider, each keeping its session label, percent and reset", () => {
    const { ink } = render(
      wide([
        providerRow("claude", session(86, "2026-08-13T03:22:00Z")),
        providerRow("codex", session(19)),
        providerRow("deepseek", session(55)),
      ]),
      400,
    );
    expect(drew(ink, "Claude")).toBeDefined();
    expect(drew(ink, "Codex")).toBeDefined();
    expect(drew(ink, "Deepseek")).toBeDefined();
    expect(drew(ink, "Session 86% · 22m")).toBeDefined();
    expect(drew(ink, "Session 19%")).toBeDefined();
  });

  it("keeps every row and the scroll label inside the panel", () => {
    const rows = Array.from({ length: VISIBLE_PROVIDER_ROWS }, (_, index) => providerRow(`p${index}`, session(index * 10)));
    const { pixels } = render(wide(rows, { total: 9, hasAbove: true, hasBelow: true }), 400);
    // The bottom two pixel rows must stay background: content that ran past the
    // panel would be clipped by the canvas and the operator would never see it.
    // Two rows rather than one because the chevrons are the lowest thing drawn.
    const bottom = pixels.subarray(399 * 4 * 98);
    for (let i = 0; i < bottom.length; i += 4) {
      expect([bottom[i], bottom[i + 1], bottom[i + 2]]).toEqual([...BACKGROUND]);
    }
  });

  // The window size lives in providerPanel.ts and the pixel budget that has to
  // hold it lives here. Raising one without retuning the other would clip a row
  // against the canvas edge — a provider silently dropped, which is the exact
  // failure the scroll replaced.
  it("leaves the label band inside the panel for the configured window size", () => {
    expect(PROVIDER_SCROLL_BAND_TOP).toBeLessThan(100);
    // Room for a 10px label plus its chevrons under the last row.
    expect(100 - PROVIDER_SCROLL_BAND_TOP).toBeGreaterThanOrEqual(12);
  });

  // The panel used to derive row height, type size and bar height from the row
  // count, so configuring a fifth provider silently shrank every row to 8px.
  // Rows are now one fixed size and the scroll label never eats into them.
  it("draws the rows at the same size and place whether or not the list scrolls", () => {
    const rows = [providerRow("a", session(10)), providerRow("b", session(20)), providerRow("c", session(30))];
    const fixed = render(wide(rows), 400).pixels;
    const scrolling = render(wide(rows, { total: 8, hasBelow: true }), 400).pixels;
    // Everything above the label band is identical; only the band differs.
    const band = 399 * 4 * PROVIDER_SCROLL_BAND_TOP;
    expect(scrolling.subarray(0, band)).toEqual(fixed.subarray(0, band));
    expect(scrolling.subarray(band)).not.toEqual(fixed.subarray(band));
  });

  it("draws no bar for a provider that reported nothing, so no bar means no data", () => {
    const withData = render(wide([providerRow("a", session(90)), providerRow("b", session(90)), providerRow("c", session(90))]), 400);
    const without = render(wide([providerRow("a", session(90)), providerRow("b", session(90)), providerRow("c", { hasData: false })]), 400);
    expect(drew(without.ink, "Awaiting data")).toBeDefined();
    expect(without.inked).toBeLessThan(withData.inked);
  });

  it("says how many providers there are in total, not how many it is showing", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    expect(drew(render(wide(rows, { total: 5, hasBelow: true }), 400).ink, "5 MODELS")).toBeDefined();
  });

  // A chevron pair that cannot move is an instruction to turn a knob that does
  // nothing, so a fleet that already fits gets no affordance at all.
  it("draws no scroll affordance when every provider is already on screen", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const { ink, pixels } = render(wide(rows), 400);
    expect(ink.some((entry) => entry.text.includes("MODELS"))).toBe(false);
    expect(inkedColumns(pixels, 400, PROVIDER_SCROLL_BAND_TOP, 100)).toEqual([]);
  });

  // The label names knob 2, so it has to sit over knob 2 — which is the strip's
  // second quarter, not the middle of the panel the label lives in. Measured on
  // the text itself, driven off the same constant the controller routes detents
  // through, so the hint and the control cannot drift apart.
  it("centres the scroll label over its own encoder, not over its panel", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const { ink } = render(wide(rows, { total: 6, hasAbove: true, hasBelow: true }), 400);
    const label = drew(ink, "6 MODELS");
    expect(label).toBeDefined();

    const context = createCanvas(400, 100).getContext("2d");
    context.font = "700 10px monospace";
    const centre = (label as Ink).x + context.measureText("6 MODELS").width / 2;
    // Panel-local x of the encoder's centre: the panel starts at the strip's
    // first quarter mark, so the panel's own centre would name no knob at all.
    expect(Math.abs(centre - (encoderCenterX(PROVIDER_SCROLL_ENCODER) - PANEL_X))).toBeLessThan(1);
    expect(centre).toBeLessThan(400 / 2);
  });

  // The painter is handed a width, never a position, so a panel drawn somewhere
  // else has to take its label with it rather than aiming at a remembered x.
  it("follows the panel when the layout puts it somewhere else", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const moved = render(wide(rows, { total: 6, hasBelow: true }, 0), 400).ink;
    const label = drew(moved, "6 MODELS");
    const context = createCanvas(400, 100).getContext("2d");
    context.font = "700 10px monospace";
    const centre = (label as Ink).x + context.measureText("6 MODELS").width / 2;
    expect(Math.abs(centre - encoderCenterX(PROVIDER_SCROLL_ENCODER))).toBeLessThan(1);
  });

  it("lights the chevron on the side that still has providers", () => {
    const rows = [providerRow("a", session(1)), providerRow("b", session(2)), providerRow("c", session(3))];
    const top = litColumns(render(wide(rows, { total: 6, hasBelow: true }), 400).pixels, 400);
    const bottom = litColumns(render(wide(rows, { total: 6, hasAbove: true }), 400).pixels, 400);
    const middle = litColumns(render(wide(rows, { total: 6, hasAbove: true, hasBelow: true }), 400).pixels, 400);

    expect(top.length).toBeGreaterThan(0);
    expect(bottom.length).toBeGreaterThan(0);
    // At the top of the list only the "more below" chevron is lit, and it sits
    // on the far side of the label from the "more above" one, so the two ends
    // of the list cannot be confused for each other.
    expect(Math.min(...top)).toBeGreaterThan(Math.max(...bottom));
    // Mid-list both are lit, which is a third distinct state.
    expect(middle.length).toBeGreaterThan(top.length);
    expect(Math.min(...middle)).toBeLessThan(Math.min(...top));
  });

  it("clips a long provider name rather than running it under the reading", () => {
    const rows = [
      providerRow("a-very-long-provider-family-name-indeed-truly", session(50)),
      providerRow("b", session(50)),
      providerRow("c", session(50)),
    ];
    expect(render(wide(rows), 400).ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });
});

describe("pager panel", () => {
  it("paints the label and one dot per window", () => {
    const { ink, inked } = render({
      kind: "pager",
      title: "MORE AGENTS",
      label: "9-16 of 32",
      model: { windowCount: 4, currentWindow: 1, dots: [false, true, false, false], hasMultiple: true },
    });
    expect(drew(ink, "9-16 of 32")).toBeDefined();
    expect(inked).toBeGreaterThan(0);
  });

  // The filled dot is the only thing that tells an operator which window they
  // are on, so a run of dots that all render identically is a real failure.
  it("draws the current window's dot differently from the rest", () => {
    const model = { windowCount: 2, currentWindow: 0, dots: [true, false], hasMultiple: true };
    const first = render({ kind: "pager", title: "MORE AGENTS", label: "1-8", model });
    const second = render({
      kind: "pager",
      title: "MORE AGENTS",
      label: "1-8",
      model: { ...model, currentWindow: 1, dots: [false, true] },
    });
    expect(Array.from(first.pixels)).not.toEqual(Array.from(second.pixels));
  });
});
