import { describe, expect, it } from "vitest";

import type { ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import { render } from "./renderSegment.js";

const row: ProviderPanelRow = {
  label: "claude",
  summaryLabel: "worst of 2 accounts",
  model: {
    provider: "claude",
    session: { usedPercent: 94, resetsAt: null },
    weekly: null,
    freshness: "fresh",
    hasData: true,
  },
};

describe("provider account summary painting", () => {
  it("paints the account summary subject alongside its reading", () => {
    const { ink } = render({ kind: "provider", row });
    expect(row.model.session?.usedPercent).toBe(94);
    expect(ink.some(({ text }) => text === "Claude")).toBe(true);
    expect(ink.some(({ text }) => text === "worst of 2 accounts")).toBe(true);
    expect(ink.some(({ text }) => text === "94%")).toBe(true);
  });

  it("paints the account summary beside its percentage in the wide panel", () => {
    const { ink } = render({
      kind: "providers",
      model: { rows: [row], total: 1, hasAbove: false, hasBelow: false },
      originX: 200,
    }, 400);
    expect(row.model.session?.usedPercent).toBe(94);
    expect(ink.some(({ text }) => text === "Claude")).toBe(true);
    expect(ink.some(({ text }) => text === "Session 94% · worst of 2")).toBe(true);
  });
});
