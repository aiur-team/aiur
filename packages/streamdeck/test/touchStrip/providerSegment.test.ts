import { describe, expect, it } from "vitest";

import {
  providerSegmentModel,
  type ProviderMeter,
} from "../../src/touchStrip/providerSegment.js";

// Mirrors the #1346 projection shape: usage.<provider>.windows keyed by the
// provider-defined limit_id, each window carrying used_percent / resets_at /
// duration_minutes (300 = 5h session, 10080 = 7d weekly).
const claudeMeter: ProviderMeter = {
  provider: "claude",
  state: "observed",
  freshness: "fresh",
  windows: {
    session: { used_percent: 42, resets_at: "2026-07-30T16:00:00Z", duration_minutes: 300 },
    weekly: { used_percent: 71, resets_at: "2026-08-02T00:00:00Z", duration_minutes: 10080 },
  },
};

describe("providerSegmentModel", () => {
  it("classifies session (shortest) and weekly (longest) by duration, not label", () => {
    const model = providerSegmentModel(claudeMeter);
    expect(model.provider).toBe("claude");
    expect(model.freshness).toBe("fresh");
    expect(model.hasData).toBe(true);
    expect(model.session).toEqual({ usedPercent: 42, resetsAt: "2026-07-30T16:00:00Z" });
    expect(model.weekly).toEqual({ usedPercent: 71, resetsAt: "2026-08-02T00:00:00Z" });
  });

  it("classifies by duration even when labels are opaque ('5h' / '7d')", () => {
    const model = providerSegmentModel({
      provider: "codex",
      windows: {
        "7d": { used_percent: 10, duration_minutes: 10080 },
        "5h": { used_percent: 90, duration_minutes: 300 },
      },
    });
    expect(model.session?.usedPercent).toBe(90);
    expect(model.weekly?.usedPercent).toBe(10);
  });

  it("clamps percentages to 0..100 and defaults missing to 0", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: {
        session: { used_percent: 140, duration_minutes: 300 },
        weekly: { used_percent: -5, duration_minutes: 10080 },
      },
    });
    expect(model.session?.usedPercent).toBe(100);
    expect(model.weekly?.usedPercent).toBe(0);
  });

  it("reports resetsAt as null when a window omits it", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: { session: { used_percent: 5, duration_minutes: 300 } },
    });
    expect(model.session).toEqual({ usedPercent: 5, resetsAt: null });
    // A single classifiable window is the session, never also the weekly.
    expect(model.weekly).toBeNull();
  });

  it("never fabricates a reading: missing meter yields an empty valid model", () => {
    for (const empty of [null, undefined]) {
      const model = providerSegmentModel(empty);
      expect(model).toEqual({
        provider: null,
        session: null,
        weekly: null,
        freshness: null,
        hasData: false,
      });
    }
  });

  it("ignores windows without a duration (cannot be classified)", () => {
    const model = providerSegmentModel({
      provider: "codex",
      windows: { mystery: { used_percent: 50 } },
    });
    expect(model.hasData).toBe(false);
    expect(model.session).toBeNull();
    expect(model.weekly).toBeNull();
  });
});
