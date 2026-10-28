import { describe, expect, it } from "vitest";

import {
  providerSegmentModel,
  type ProviderMeter,
} from "../../src/touchStrip/providerSegment.js";

// Codex's real projection shape (#1346): two windows carrying
// `duration_minutes` (from `windowDurationMins`) — 300 = 5h session,
// 10080 = 7d weekly — keyed by the provider-defined limit_id.
const codexMeter: ProviderMeter = {
  provider: "codex",
  state: "observed",
  freshness: "fresh",
  windows: {
    "5h:primary": { used_percent: 42, resets_at: "2026-07-30T16:00:00Z", duration_minutes: 300 },
    "7d:secondary": { used_percent: 71, resets_at: "2026-08-02T00:00:00Z", duration_minutes: 10080 },
  },
};

// Claude's real projection shape: the app-server adapter
// (`src/lib/aiur/claude/rate_limit_adapter.ex`) emits a SINGLE `"rate-limit"`
// window with used_percent / resets_at and NO duration_minutes. This is the
// shape the segment must render as real session usage, not "awaiting data".
const claudeMeter: ProviderMeter = {
  provider: "claude",
  state: "observed",
  freshness: "fresh",
  windows: {
    "rate-limit": { used_percent: 63, resets_at: "2026-07-30T16:00:00Z" },
  },
};

describe("providerSegmentModel", () => {
  it("reads the daemon semantic slots without durations and prioritizes their keys", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: {
        session: { remaining_percent: 12, used_percent: 88 },
        weekly: { remaining_percent: 40, used_percent: 60 },
        legacy: { used_percent: 1, duration_minutes: 1 },
      },
    });
    expect(model.hasData).toBe(true);
    expect(model.session).toEqual({ usedPercent: 88, resetsAt: null });
    expect(model.weekly).toEqual({ usedPercent: 60, resetsAt: null });
  });

  it("never turns unknown semantic readings into zero", () => {
    const readings: ProviderMeter[] = [{ windows: {} }, { windows: { session: { used_percent: null }, weekly: { used_percent: null } } }];
    for (const reading of readings) {
      const model = providerSegmentModel({ provider: "codex", state: "unknown", ...reading });
      expect(model.hasData).toBe(false);
      expect(model.session).toBeNull();
      expect(model.weekly).toBeNull();
    }
    expect(providerSegmentModel({ windows: { weekly: { used_percent: 60 } } }).weekly?.usedPercent).toBe(60);
  });

  it("classifies session (shortest) and weekly (longest) by duration, not label", () => {
    const model = providerSegmentModel(codexMeter);
    expect(model.provider).toBe("codex");
    expect(model.freshness).toBe("fresh");
    expect(model.hasData).toBe(true);
    expect(model.session).toEqual({ usedPercent: 42, resetsAt: "2026-07-30T16:00:00Z" });
    expect(model.weekly).toEqual({ usedPercent: 71, resetsAt: "2026-08-02T00:00:00Z" });
  });

  it("treats Claude's single duration-less window as the real session (no weekly, has data)", () => {
    const model = providerSegmentModel(claudeMeter);
    expect(model.provider).toBe("claude");
    expect(model.hasData).toBe(true);
    expect(model.session).toEqual({ usedPercent: 63, resetsAt: "2026-07-30T16:00:00Z" });
    expect(model.weekly).toBeNull();
  });

  it("stays ambiguous (no data) when two-plus windows all lack a duration", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: {
        a: { used_percent: 10 },
        b: { used_percent: 20 },
      },
    });
    expect(model.hasData).toBe(false);
    expect(model.session).toBeNull();
    expect(model.weekly).toBeNull();
  });

  it("drops the duplicate weekly when two distinct windows share a duration (tie -> first-seen session only)", () => {
    const model = providerSegmentModel({
      provider: "codex",
      windows: {
        first: { used_percent: 30, duration_minutes: 300 },
        second: { used_percent: 80, duration_minutes: 300 },
      },
    });
    expect(model.session?.usedPercent).toBe(30);
    expect(model.weekly).toBeNull();
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

  it("keeps a semantic window unknown when used_percent is absent", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: { session: { resets_at: "2026-07-30T16:00:00Z", duration_minutes: 300 } },
    });
    expect(model.session).toBeNull();
    expect(model.hasData).toBe(false);
  });

  it("nulls provider/freshness and defaults windows for a bare meter object", () => {
    const model = providerSegmentModel({});
    expect(model).toEqual({
      provider: null,
      session: null,
      weekly: null,
      freshness: null,
      hasData: false,
    });
  });

  it("falls back to session for a lone window without a duration", () => {
    const model = providerSegmentModel({
      provider: "codex",
      windows: { mystery: { used_percent: 50 } },
    });
    expect(model.hasData).toBe(true);
    expect(model.session?.usedPercent).toBe(50);
    expect(model.weekly).toBeNull();
  });

  it("reports no data (never a fabricated 0%) for a lone window without a used_percent (#1436)", () => {
    const model = providerSegmentModel({
      provider: "claude",
      windows: { "rate-limit": { resets_at: "2026-07-30T16:00:00Z" } },
    });
    expect(model.hasData).toBe(false);
    expect(model.session).toBeNull();
    expect(model.weekly).toBeNull();
  });
});
