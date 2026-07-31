import { describe, expect, it } from "vitest";

import { SEGMENT_COUNT } from "../../src/touchStrip/geometry.js";
import { pagerModel } from "../../src/touchStrip/pagerSegment.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { summaryModel } from "../../src/touchStrip/summarySegment.js";
import { composeStrip } from "../../src/touchStrip/stripLayout.js";

const grid = () =>
  composeStrip({
    mode: "grid",
    data: {
      summary: summaryModel(2, 3),
      claude: providerSegmentModel(null),
      codex: providerSegmentModel(null),
      pager: pagerModel(9, 4, 1),
      pagerLabel: "5-8",
    },
  });

describe("composeStrip", () => {
  it("always yields exactly SEGMENT_COUNT segments", () => {
    expect(grid()).toHaveLength(SEGMENT_COUNT);
    expect(
      composeStrip({
        mode: "cmd",
        data: { identity: "agent-7", status: "working", percent: 40, ticketId: "1356" },
      }),
    ).toHaveLength(SEGMENT_COUNT);
    expect(
      composeStrip({ mode: "logs", data: { lines: ["a", "b"] } }),
    ).toHaveLength(SEGMENT_COUNT);
  });

  it("grid mode: [summary, Claude, Codex, pager] in order", () => {
    const [s0, s1, s2, s3] = grid();
    expect(s0.kind).toBe("summary");
    expect(s1).toMatchObject({ kind: "provider", label: "Claude" });
    expect(s2).toMatchObject({ kind: "provider", label: "Codex" });
    expect(s3).toMatchObject({ kind: "pager", title: "MORE AGENTS", label: "5-8" });
  });

  it("cmd mode: pager region becomes the controlling ticket and a BACK hint appears", () => {
    const [s0, s1, s2, s3] = composeStrip({
      mode: "cmd",
      data: { identity: "agent-7", status: "working", percent: 140, ticketId: "1356" },
    });
    expect(s0).toMatchObject({ kind: "agentIdentity", identity: "agent-7" });
    // percent is clamped into 0..100.
    expect(s1).toMatchObject({ kind: "agentProgress", status: "working", percent: 100 });
    expect(s2).toMatchObject({ kind: "hint", label: "BACK" });
    expect(s3).toMatchObject({ kind: "controlling", ticketId: "1356" });
  });

  it("cmd mode: out-of-range percents clamp into 0..100", () => {
    const [, nan] = composeStrip({
      mode: "cmd",
      data: { identity: "agent-7", status: "idle", percent: Number.NaN, ticketId: "1356" },
    });
    expect(nan).toMatchObject({ kind: "agentProgress", percent: 0 });

    const [, negative] = composeStrip({
      mode: "cmd",
      data: { identity: "agent-7", status: "idle", percent: -10, ticketId: "1356" },
    });
    expect(negative).toMatchObject({ kind: "agentProgress", percent: 0 });
  });

  it("logs mode: BACK / chat line 1 / chat line 2 / EVENTS", () => {
    const [s0, s1, s2, s3] = composeStrip({
      mode: "logs",
      data: { lines: ["first", "second", "ignored-third"] },
    });
    expect(s0).toMatchObject({ kind: "hint", label: "BACK" });
    expect(s1).toMatchObject({ kind: "chat", line: "first" });
    expect(s2).toMatchObject({ kind: "chat", line: "second" });
    expect(s3).toMatchObject({ kind: "hint", label: "EVENTS" });
  });

  it("logs mode fills missing chat lines with empty strings", () => {
    const [, s1, s2] = composeStrip({ mode: "logs", data: { lines: [] } });
    expect(s1).toMatchObject({ kind: "chat", line: "" });
    expect(s2).toMatchObject({ kind: "chat", line: "" });
  });
});
