import { describe, expect, it } from "vitest";

import { agentActivity, agentDetailModel, elapsedLabel } from "../../src/touchStrip/agentDetail.js";

describe("elapsedLabel", () => {
  it("reads seconds, then minutes, then hours with padded minutes", () => {
    expect(elapsedLabel(0)).toBe("0s");
    expect(elapsedLabel(59)).toBe("59s");
    expect(elapsedLabel(60)).toBe("1m");
    expect(elapsedLabel(3_599)).toBe("59m");
    expect(elapsedLabel(3_600)).toBe("1h 00m");
    expect(elapsedLabel(11_240)).toBe("3h 07m");
  });

  it("has no reading for an absent, negative or non-finite runtime", () => {
    expect(elapsedLabel(undefined)).toBeNull();
    expect(elapsedLabel(null)).toBeNull();
    expect(elapsedLabel(-1)).toBeNull();
    expect(elapsedLabel(Number.NaN)).toBeNull();
    expect(elapsedLabel("3600")).toBeNull();
  });
});

describe("agentActivity", () => {
  it("maps each workflow stage to its own glyph", () => {
    expect(agentActivity("brainstorm")).toEqual({ glyph: "brainstorm", label: "Brainstorming" });
    expect(agentActivity("plan")).toEqual({ glyph: "plan", label: "Planning" });
    expect(agentActivity("work")).toEqual({ glyph: "work", label: "Working" });
    expect(agentActivity("review")).toEqual({ glyph: "review", label: "Reviewing" });
  });

  it("gives every wait the shared clock glyph and its own words", () => {
    expect(agentActivity("waiting_ci")).toEqual({ glyph: "waiting", label: "Waiting on CI" });
    expect(agentActivity("waiting_review")?.label).toBe("Waiting for review");
    expect(agentActivity("waiting_human")?.glyph).toBe("waiting");
    expect(agentActivity("waiting_dependency")?.glyph).toBe("waiting");
  });

  /** The deck never guesses: no activity from the daemon means none is shown. */
  it("has no activity for an absent or unrecognised value", () => {
    expect(agentActivity(undefined)).toBeNull();
    expect(agentActivity(null)).toBeNull();
    expect(agentActivity("napping")).toBeNull();
    expect(agentActivity(7)).toBeNull();
  });
});

describe("agentDetailModel", () => {
  it("carries the whole readout from one projected agent", () => {
    expect(
      agentDetailModel({
        identifier: "1356",
        title: "Restore retry statistics",
        icon: "database",
        vendor: "codex",
        bucket: "running",
        progress_percent: 72,
        runtime_seconds: 11_240,
        activity: "waiting_ci",
      }),
    ).toEqual({
      ticketId: "1356",
      title: "Restore retry statistics",
      icon: "database",
      vendor: "codex",
      status: "running",
      percent: 72,
      freshness: "fresh",
      elapsedLabel: "3h 07m",
      activity: { glyph: "waiting", label: "Waiting on CI" },
    });
  });

  /**
   * A missing reading is null here for the same reason it is null on the key
   * face. Returning 0 put "0%" and a full-width red meter on the 800px readout
   * one key press after that ticket's key painted a dashed no-reading track —
   * two contradictory claims about one ticket.
   */
  it("clamps a real percentage into 0..100 and reads an absent one as unknown", () => {
    expect(agentDetailModel({ progress_percent: 140 }).percent).toBe(100);
    expect(agentDetailModel({ progress_percent: -10 }).percent).toBe(0);
    expect(agentDetailModel({ progress_percent: 0 }).percent).toBe(0);
    expect(agentDetailModel({ progress_percent: Number.NaN }).percent).toBeNull();
    expect(agentDetailModel({ progress_percent: null }).percent).toBeNull();
    expect(agentDetailModel({}).percent).toBeNull();
  });

  it("preserves stale readings and fails closed on unknown freshness", () => {
    expect(agentDetailModel({ progress_percent: 70, progress_freshness: "stale" })).toMatchObject({ percent: 70, freshness: "stale" });
    expect(agentDetailModel({ progress_percent: 70, progress_freshness: "unknown" })).toMatchObject({ percent: null, freshness: "unknown" });
    expect(agentDetailModel({ progress_percent: 70, progress_freshness: "future" })).toMatchObject({ percent: 70, freshness: "stale" });
  });

  it("falls back to printable text rather than leaving the panel blank", () => {
    expect(agentDetailModel({})).toMatchObject({
      ticketId: "—",
      title: "Untitled ticket",
      icon: "",
      vendor: "unknown",
      status: "unknown",
      elapsedLabel: null,
      activity: null,
    });
    expect(agentDetailModel({ identifier: "", title: "" })).toMatchObject({ ticketId: "—", title: "Untitled ticket" });
  });
});
