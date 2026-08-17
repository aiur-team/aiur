import { describe, expect, it } from "vitest";

import { createPhysicalController } from "../src/controller.js";
import { advanceDemoGrid, advanceDemoLogs, demoGrid, demoLogs, demoUsage } from "../src/demo.js";
import { maxProviderOffset } from "../src/touchStrip/providerPanel.js";
import { providerSegmentModel, type ProviderMeter } from "../src/touchStrip/providerSegment.js";
import { keyReport } from "./support/deckReports.js";

describe("demo logs fixture", () => {
  const logs = demoLogs(Date.parse("2026-08-13T03:00:00Z"));
  const eventKeys = logs.event_keys ?? [];
  const transcript = logs.transcript ?? [];

  it("ends with the LIVE row, one key per event before it", () => {
    expect(eventKeys[eventKeys.length - 1]).toMatchObject({ kind: "live" });
    expect(eventKeys.slice(0, -1).every((key) => key.kind === "event")).toBe(true);
  });

  // The origin anchor is what gives the surface a left edge. Without it the
  // oldest transcript rows sit above every header and no key can reach them.
  it("opens on an origin event", () => {
    expect(eventKeys[0]).toMatchObject({ kind: "event", text: "Ticket opened" });
    expect(transcript[0]).toMatchObject({ kind: "event_header", label: "Ticket opened" });
  });

  // The whole point of the fixture is to demonstrate jump-to-event with no
  // daemon, which needs a header per key, in the same order as the keys.
  it("gives every event key a matching header in the transcript", () => {
    const headers = transcript.filter((row) => row.kind === "event_header");
    expect(headers).toHaveLength(eventKeys.length - 1);
    headers.forEach((header, index) => {
      expect(header.label).toBe(eventKeys[index].text);
      expect(header.badge).toBe(eventKeys[index].badge);
    });
  });

  // Each key's own `start` is what the press jumps to, so a fixture whose
  // starts did not land on headers would exercise a path production never takes.
  it("points every key's start at its own header", () => {
    eventKeys.slice(0, -1).forEach((key) => {
      expect(transcript[key.start as number]).toMatchObject({ kind: "event_header", label: key.text });
    });
    expect(eventKeys[eventKeys.length - 1].start).toBe(transcript.length - 1);
  });

  it("carries both diff and message entries under its events", () => {
    expect(transcript.some((row) => row.kind === "diff")).toBe(true);
    expect(transcript.some((row) => row.kind === "message")).toBe(true);
  });

  // Real hunk lines, each its own row, not a one-line summary: the bottom
  // panel renders a diff the operator can read and scroll through.
  it("unrolls each diff into a header row plus one row per hunk line", () => {
    const lines = transcript.filter((row) => row.kind === "diff_line");
    expect(transcript.some((row) => row.kind === "diff")).toBe(true);
    expect(lines.some((line) => line.sign === "+")).toBe(true);
    expect(lines.some((line) => line.sign === "-")).toBe(true);
    expect(lines.some((line) => line.sign === " ")).toBe(true);
    // Every hunk line follows a header or another hunk line — never floats free.
    lines.forEach((line) => {
      const previous = transcript[transcript.indexOf(line) - 1];
      expect(["diff", "diff_line"]).toContain(previous.kind);
    });
  });

  // Every role the transcript renderer styles differently has to appear, or the
  // fixture cannot show that the styling works.
  it("covers every transcript role the renderer styles differently", () => {
    const roles = new Set(transcript.filter((row) => row.kind === "message").map((row) => row.role));
    expect([...roles].sort()).toEqual(["alert", "assistant", "ci", "command", "reasoning", "system", "tool", "user"]);
  });

  it("orders events oldest first, the direction the surface reads in", () => {
    const stamps = transcript
      .filter((row) => row.kind === "event_header")
      .map((row) => Date.parse(String(row.timestamp)));
    expect(stamps).toEqual([...stamps].sort((left, right) => left - right));
  });

  it("lands on the pressed event's header on-device", () => {
    const controller = createPhysicalController({ grid: demoGrid, channel: () => null, stateChanged: () => undefined });
    controller.setLogs(logs);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(1, true));
    controller.handleReport(keyReport(1, false));
    expect(controller.state().mode).toBe("logs");

    const offset = controller.state().eventOffset;
    controller.handleReport(keyReport(2, true));
    controller.handleReport(keyReport(2, false));
    expect(controller.state().transcriptRows[0]).toMatchObject({
      kind: "event_header",
      label: eventKeys[offset + 2].text,
    });
    expect(controller.state().selectedEvent).toBe(offset + 2);
  });
});

describe("demo grid fixture", () => {
  // The fixture exists because a real fleet is often all one colour; if it did
  // not cover every bucket it could not prove the state colours work at all.
  it("covers every key state, both footer shapes and several providers", () => {
    const grid = demoGrid();
    const buckets = new Set(grid.agents.map((agent) => agent.bucket));
    expect([...buckets].sort()).toEqual(["alert", "paused", "queued", "running", "stuck"]);
    expect(grid.agents.some((agent) => agent.priority === true)).toBe(true);
    expect(grid.agents.some((agent) => agent.dependency_ready === false)).toBe(true);
    expect(new Set(grid.agents.map((agent) => agent.vendor)).size).toBeGreaterThan(2);
  });

  it("reports a total and paging bounds that match its own agent list", () => {
    const grid = demoGrid();
    expect(grid.total).toBe(grid.agents.length);
    expect(grid.max_column_offset).toBe(Math.max(0, Math.ceil(grid.agents.length / 2) - 4));
  });

  it("carries a build order in progress so the summary shows its bar", () => {
    const grid = demoGrid() as unknown as { build: { completed: number; total: number; etaSeconds: number } };
    expect(grid.build.completed).toBeGreaterThan(0);
    expect(grid.build.completed).toBeLessThan(grid.build.total);
    expect(grid.build.etaSeconds).toBeGreaterThan(0);
  });
});

describe("demoUsage fixture", () => {
  const now = Date.parse("2026-08-13T03:00:00Z");
  const usage = demoUsage(now) as Readonly<Record<string, ProviderMeter>>;

  it("projects to real session and weekly windows resetting in the future", () => {
    const claude = providerSegmentModel(usage.claude);
    expect(claude.hasData).toBe(true);
    expect(claude.session?.remainingPercent).toBe(14);
    expect(Date.parse(String(claude.session?.resetsAt))).toBeGreaterThan(now);
    expect(Date.parse(String(claude.weekly?.resetsAt))).toBeGreaterThan(now);
  });

  // "Awaiting data" is a state the operator has to be able to see on-device,
  // so one provider deliberately reports no windows at all.
  it("includes a provider with no reading so that state is visible too", () => {
    expect(providerSegmentModel(usage.openrouter).hasData).toBe(false);
  });

  // Demo mode is where the provider scroll gets looked at without a fleet
  // behind it, so the fixture has to hold more providers than the panel shows.
  it("configures more providers than the strip shows at once, so the scroll is exercised", () => {
    expect(maxProviderOffset(Object.keys(usage).length)).toBeGreaterThan(0);
  });

  it("spreads the meters so no two segments read alike", () => {
    const percents = Object.values(usage)
      .map((meter) => providerSegmentModel(meter).session?.remainingPercent)
      .filter((percent): percent is number => percent !== undefined);
    expect(new Set(percents).size).toBe(percents.length);
  });
});

describe("demo progress states", () => {
  // The three states have to be side by side in the fixture, because the whole
  // point of the change is that they are now distinguishable by eye.
  it("covers a fresh reading, a retained stale one, an unknown one, and a real zero", () => {
    const agents = demoGrid().agents;
    const at = (identifier: string) => agents.find((agent) => agent.identifier === identifier);
    expect(at("401")).toMatchObject({ progress_freshness: "fresh" });
    expect(at("333")).toMatchObject({ progress_freshness: "stale", progress_percent: 34 });
    expect(at("640")).toMatchObject({ progress_freshness: "unknown", progress_percent: null });
    expect(at("412")).toMatchObject({ progress_freshness: "fresh", progress_percent: 0 });
  });
});

describe("advanceDemoGrid", () => {
  it("advances running agents with a fresh reading, leaving every other row alone", () => {
    const before = demoGrid();
    const after = advanceDemoGrid(before, 5);
    after.agents.forEach((agent, index) => {
      const previous = before.agents[index];
      const advances =
        previous.bucket === "running" &&
        typeof previous.progress_percent === "number" &&
        previous.progress_freshness === "fresh";
      const expected = advances ? Math.min(100, (previous.progress_percent as number) + 5) : previous.progress_percent;
      expect(agent.progress_percent, `agent ${String(previous.identifier)}`).toBe(expected);
    });
  });

  /**
   * The tick used to wrap at 101, which walked a running agent from 99 back
   * through 3 — a synthetic version of the exact 0-then-70-then-0 flicker this
   * change exists to remove. A demo that reproduces the bug on purpose cannot
   * be used to confirm the bug is gone.
   */
  it("holds at 100 instead of wrapping back through zero", () => {
    const grid = { ...demoGrid(), agents: [{ identifier: "1", bucket: "running", progress_percent: 99, progress_freshness: "fresh" }] };
    expect(advanceDemoGrid(grid, 5).agents[0].progress_percent).toBe(100);
  });

  it("never advances a stale or unknown reading", () => {
    const grid = {
      ...demoGrid(),
      agents: [
        { identifier: "1", bucket: "running", progress_percent: 40, progress_freshness: "stale" },
        { identifier: "2", bucket: "running", progress_percent: null, progress_freshness: "unknown" },
      ],
    };
    const after = advanceDemoGrid(grid, 5).agents;
    expect(after[0].progress_percent).toBe(40);
    expect(after[1].progress_percent).toBeNull();
  });

  it("leaves the rest of the payload untouched", () => {
    const before = demoGrid();
    const after = advanceDemoGrid(before, 7);
    expect(after.total).toBe(before.total);
    expect(after.max_column_offset).toBe(before.max_column_offset);
    expect(after.agents).toHaveLength(before.agents.length);
  });
});

describe("advanceDemoLogs", () => {
  const logs = demoLogs(Date.parse("2026-08-13T03:00:00Z"));

  it("grows the newest message a clause at a time, so the reveal has something to reveal", () => {
    const first = advanceDemoLogs(logs, 0).transcript ?? [];
    const second = advanceDemoLogs(logs, 1).transcript ?? [];
    const bodyOf = (rows: readonly Record<string, unknown>[]) => String(rows[rows.length - 1].body);
    expect(bodyOf(second).startsWith(bodyOf(first))).toBe(true);
    expect(bodyOf(second).length).toBeGreaterThan(bodyOf(first).length);
  });

  it("only ever rewrites the last row", () => {
    const advanced = advanceDemoLogs(logs, 2).transcript ?? [];
    const original = logs.transcript ?? [];
    expect(advanced).toHaveLength(original.length);
    expect(advanced.slice(0, -1)).toEqual(original.slice(0, -1));
  });

  it("leaves a feed it cannot type into alone", () => {
    expect(advanceDemoLogs({}, 0)).toEqual({});
    expect(advanceDemoLogs({ transcript: [] }, 0).transcript).toEqual([]);
    const headerOnly = { transcript: [{ kind: "event_header", body: "x", label: "x", badge: "INFO", timestamp: null }] };
    expect(advanceDemoLogs(headerOnly, 0)).toEqual(headerOnly);
  });
});
