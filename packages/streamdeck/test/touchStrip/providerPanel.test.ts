import { describe, expect, it } from "vitest";

import {
  maxProviderOffset,
  providerPanelModel,
  providerRows,
  VISIBLE_PROVIDER_ROWS,
  type ProviderPanelRow,
} from "../../src/touchStrip/providerPanel.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";

const meter = (provider: string, usedPercent: number) => ({
  provider,
  windows: { session: { used_percent: usedPercent, duration_minutes: 300 } },
});

const row = (label: string, usedPercent: number): ProviderPanelRow => ({
  label,
  model: providerSegmentModel(meter(label, usedPercent)),
});

const labels = (rows: readonly ProviderPanelRow[]): string[] => rows.map((entry) => entry.label);

describe("providerRows", () => {
  it("turns the projected usage map into one row per provider", () => {
    const rows = providerRows({ claude: meter("claude", 86), codex: meter("codex", 19) });
    expect(labels(rows)).toEqual(["claude", "codex"]);
    expect(rows[0].model.session?.remainingPercent).toBe(14);
  });

  it("orders providers alphabetically, not by the payload's own key order", () => {
    expect(labels(providerRows({ kimi: meter("kimi", 1), claude: meter("claude", 2), deepseek: meter("deepseek", 3) }))).toEqual([
      "claude",
      "deepseek",
      "kimi",
    ]);
  });

  it("keeps a provider that reported no windows, so its silence is visible", () => {
    const [openrouter] = providerRows({ openrouter: { provider: "openrouter", windows: {} } });
    expect(openrouter.label).toBe("openrouter");
    expect(openrouter.model.hasData).toBe(false);
  });

  // Dropping a broken meter would hide a configured provider AND take three
  // providers back under the wide-panel threshold, so the strip would look like
  // an ordinary two-provider fleet.
  it("keeps a provider whose payload is not a meter, reporting no data for it", () => {
    const rows = providerRows({ claude: meter("claude", 5), broken: null, odd: 3 });
    expect(labels(rows)).toEqual(["broken", "claude", "odd"]);
    expect(rows[0].model.hasData).toBe(false);
    expect(rows[2].model.hasData).toBe(false);
  });

  it("yields no rows for an empty usage payload", () => {
    expect(providerRows({})).toEqual([]);
  });
});

describe("maxProviderOffset", () => {
  it("is zero while every provider already fits, so the knob has nowhere to go", () => {
    expect(maxProviderOffset(0)).toBe(0);
    expect(maxProviderOffset(VISIBLE_PROVIDER_ROWS)).toBe(0);
  });

  // The last window must be a full one: stopping short would leave the panel
  // half empty at the end of the list, and running past it would show nothing.
  it("stops at the offset whose window ends on the last provider", () => {
    expect(maxProviderOffset(VISIBLE_PROVIDER_ROWS + 1)).toBe(1);
    expect(maxProviderOffset(9)).toBe(9 - VISIBLE_PROVIDER_ROWS);
  });
});

describe("providerPanelModel", () => {
  const many = (count: number): ProviderPanelRow[] => Array.from({ length: count }, (_, index) => row(`p${index}`, index));

  it("shows every provider when they all fit, and reports nothing to scroll to", () => {
    const rows = [row("claude", 10), row("codex", 20), row("kimi", 30)];
    expect(providerPanelModel(rows, 0)).toEqual({ rows, total: 3, hasAbove: false, hasBelow: false });
  });

  it("shows a fixed-size window rather than shrinking to fit every provider", () => {
    const model = providerPanelModel(many(9), 0);
    expect(model.rows).toHaveLength(VISIBLE_PROVIDER_ROWS);
    // The count the panel prints is the fleet's, not the window's.
    expect(model.total).toBe(9);
  });

  it("moves the window one provider per offset, keeping the caller's order", () => {
    const rows = many(5);
    expect(labels(providerPanelModel(rows, 0).rows)).toEqual(["p0", "p1", "p2"]);
    expect(labels(providerPanelModel(rows, 1).rows)).toEqual(["p1", "p2", "p3"]);
    expect(labels(providerPanelModel(rows, 2).rows)).toEqual(["p2", "p3", "p4"]);
  });

  // Every provider must be reachable. The panel used to drop the least
  // constrained ones and print "+N MORE PROVIDERS", so a provider at 4% had no
  // control anywhere on the deck that would show it.
  it("reaches every provider across the offsets, dropping none", () => {
    const rows = many(7);
    const seen = new Set<string>();
    for (let offset = 0; offset <= maxProviderOffset(rows.length); offset += 1) {
      for (const visible of providerPanelModel(rows, offset).rows) seen.add(visible.label);
    }
    expect([...seen].sort()).toEqual(labels(rows).sort());
  });

  it("reports which directions still have providers in them", () => {
    const rows = many(5);
    expect(providerPanelModel(rows, 0)).toMatchObject({ hasAbove: false, hasBelow: true });
    expect(providerPanelModel(rows, 1)).toMatchObject({ hasAbove: true, hasBelow: true });
    expect(providerPanelModel(rows, 2)).toMatchObject({ hasAbove: true, hasBelow: false });
  });

  // The provider list is the daemon's; one disappearing between two pushes must
  // not leave the panel parked on an empty window.
  it("clamps an offset past the end of a shrunken list", () => {
    expect(labels(providerPanelModel(many(4), 9).rows)).toEqual(["p1", "p2", "p3"]);
    expect(providerPanelModel(many(3), 2)).toMatchObject({ hasAbove: false, hasBelow: false });
    expect(labels(providerPanelModel(many(5), -3).rows)).toEqual(["p0", "p1", "p2"]);
  });

  it("keeps a provider with no reading in the window rather than sorting it away", () => {
    const silent: ProviderPanelRow = { label: "silent", model: providerSegmentModel({ provider: "silent", windows: {} }) };
    expect(labels(providerPanelModel([silent, row("a", 1), row("b", 2)], 0).rows)).toEqual(["silent", "a", "b"]);
  });

  // Math.min/Math.max propagate NaN and slice(NaN, NaN) returns nothing, so an
  // unguarded clamp would paint a configured fleet as an empty panel — worse
  // than any wrong window. Reachable from render-demo.mjs's parseInt of argv.
  it("treats a non-finite offset as the top of the list, not an empty window", () => {
    expect(labels(providerPanelModel(many(5), Number.NaN).rows)).toEqual(["p0", "p1", "p2"]);
    expect(labels(providerPanelModel(many(5), Number.POSITIVE_INFINITY).rows)).toEqual(["p0", "p1", "p2"]);
    expect(labels(providerPanelModel(many(5), 1.7).rows)).toEqual(["p1", "p2", "p3"]);
  });
});
