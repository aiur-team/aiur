import { describe, expect, it } from "vitest";

import { SEGMENT_COUNT } from "../../src/touchStrip/geometry.js";
import { pagerModel } from "../../src/touchStrip/pagerSegment.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { summaryModel } from "../../src/touchStrip/summarySegment.js";
import { composeStrip } from "../../src/touchStrip/stripLayout.js";
import type { TranscriptRow } from "../../src/channel.js";

const message = (body: string): TranscriptRow => ({ kind: "message", role: "assistant", body });

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
      composeStrip({ mode: "logs", data: { rows: [message("a"), message("b")] } }),
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

  it("logs mode: BACK / chat row 1 / chat row 2 / EVENTS", () => {
    const [s0, s1, s2, s3] = composeStrip({
      mode: "logs",
      data: { rows: [message("first"), message("second"), message("ignored-third")] },
    });
    expect(s0).toMatchObject({ kind: "hint", label: "BACK" });
    expect(s1).toMatchObject({ kind: "chat", row: message("first") });
    expect(s2).toMatchObject({ kind: "chat", row: message("second") });
    expect(s3).toMatchObject({ kind: "hint", label: "EVENTS" });
  });

  // A slot past the end of the transcript carries no row at all, so the painter
  // can leave it blank instead of rendering an empty message.
  it("logs mode leaves missing chat rows null", () => {
    const [, s1, s2] = composeStrip({ mode: "logs", data: { rows: [] } });
    expect(s1).toMatchObject({ kind: "chat", row: null });
    expect(s2).toMatchObject({ kind: "chat", row: null });
  });

  it("logs mode carries each row shape through to the painter", () => {
    const header: TranscriptRow = { kind: "event_header", badge: "EMIT", body: "Dependency cleared", timestamp: "2026-08-13T03:00:00Z" };
    const diff: TranscriptRow = { kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: null };
    const [, s1, s2] = composeStrip({ mode: "logs", data: { rows: [header, diff] } });
    expect(s1).toMatchObject({ kind: "chat", row: header });
    expect(s2).toMatchObject({ kind: "chat", row: diff });
  });

  it("logs mode exposes independent chat and event bounds", () => {
    const [back, , , events] = composeStrip({
      mode: "logs",
      data: { rows: [message("chat")], chatHasNext: true, eventHasPrevious: true, eventHasNext: true },
    });
    expect(back).toMatchObject({ kind: "hint", label: "CHAT", direction: "forward" });
    expect(events).toMatchObject({ kind: "hint", label: "EVENTS ↑↓", direction: "back" });
  });

  it("renders one-sided event and chat bounds", () => {
    expect(composeStrip({ mode: "logs", data: { rows: [], eventHasPrevious: true } })[3]).toMatchObject({ label: "EVENTS ↑" });
    expect(composeStrip({ mode: "logs", data: { rows: [], eventHasNext: true } })[3]).toMatchObject({ label: "EVENTS ↓" });
    expect(composeStrip({ mode: "logs", data: { rows: [], chatHasPrevious: true } })[0]).toMatchObject({ label: "CHAT" });
  });
});
