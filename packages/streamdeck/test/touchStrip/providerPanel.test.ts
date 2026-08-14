import { describe, expect, it } from "vitest";

import { MAX_PROVIDER_ROWS, providerPanelModel, providerRows, type ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
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
    expect(rows[0].model.session?.usedPercent).toBe(86);
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

describe("providerPanelModel", () => {
  it("shows every provider when they all fit", () => {
    const rows = [row("claude", 10), row("codex", 20), row("kimi", 30)];
    expect(providerPanelModel(rows)).toEqual({ rows, overflow: 0 });
  });

  it("shows exactly the maximum without reporting an overflow", () => {
    const rows = Array.from({ length: MAX_PROVIDER_ROWS }, (_, index) => row(`p${index}`, index));
    expect(providerPanelModel(rows).overflow).toBe(0);
    expect(providerPanelModel(rows).rows).toHaveLength(MAX_PROVIDER_ROWS);
  });

  it("keeps the most-constrained providers when there are too many, in the given order", () => {
    const rows = [row("a", 5), row("b", 90), row("c", 10), row("d", 80), row("e", 70), row("f", 60)];
    const model = providerPanelModel(rows);
    // b/d/e/f are the four closest to their limits; a and c are dropped.
    expect(labels(model.rows)).toEqual(["b", "d", "e", "f"]);
    expect(model.overflow).toBe(2);
  });

  it("drops providers with no reading before providers with a real one", () => {
    const silent: ProviderPanelRow = { label: "silent", model: providerSegmentModel({ provider: "silent", windows: {} }) };
    const rows = [silent, row("a", 1), row("b", 2), row("c", 3), row("d", 4), row("e", 5)];
    expect(labels(providerPanelModel(rows).rows)).toEqual(["b", "c", "d", "e"]);
  });
});
