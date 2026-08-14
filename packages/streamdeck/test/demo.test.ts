import { describe, expect, it } from "vitest";

import { createPhysicalController } from "../src/controller.js";
import { advanceDemoGrid, demoGrid, demoLogs, demoUsage } from "../src/demo.js";
import { maxProviderOffset } from "../src/touchStrip/providerPanel.js";
import { providerSegmentModel, type ProviderMeter } from "../src/touchStrip/providerSegment.js";
import { keyReport } from "./support/deckReports.js";

describe("demo logs fixture", () => {
  const logs = demoLogs(Date.parse("2026-08-13T03:00:00Z"));
  const eventKeys = logs.event_keys ?? [];
  const transcript = logs.transcript ?? [];

  it("leads with the LIVE row and one key per event", () => {
    expect(eventKeys[0]).toMatchObject({ kind: "live" });
    expect(eventKeys.slice(1).every((key) => key.kind === "event")).toBe(true);
  });

  // The whole point of the fixture is to demonstrate jump-to-event with no
  // daemon, which needs a header per key, in the same order as the keys.
  it("gives every event key a matching header in the transcript", () => {
    const headers = transcript.filter((row) => row.kind === "event_header");
    expect(headers).toHaveLength(eventKeys.length - 1);
    headers.forEach((header, index) => {
      expect(header.body).toBe(eventKeys[index + 1].text);
      expect(header.badge).toBe(eventKeys[index + 1].badge);
    });
  });

  it("carries both diff and message entries under its events", () => {
    expect(transcript.some((row) => row.kind === "diff")).toBe(true);
    expect(transcript.some((row) => row.kind === "message")).toBe(true);
  });

  it("orders events newest first, matching the daemon's flattening", () => {
    const stamps = transcript
      .filter((row) => row.kind === "event_header")
      .map((row) => Date.parse(String(row.timestamp)));
    expect(stamps).toEqual([...stamps].sort((left, right) => right - left));
  });

  it("lands on the pressed event's header on-device", () => {
    const controller = createPhysicalController({ grid: demoGrid, channel: () => null, stateChanged: () => undefined });
    controller.setLogs(logs);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(2, true));
    controller.handleReport(keyReport(2, false));
    expect(controller.state().mode).toBe("logs");

    controller.handleReport(keyReport(2, true));
    controller.handleReport(keyReport(2, false));
    expect(controller.state().transcriptRows[0]).toMatchObject({ kind: "event_header", body: eventKeys[2].text });
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
    expect(claude.session?.usedPercent).toBe(86);
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
      .map((meter) => providerSegmentModel(meter).session?.usedPercent)
      .filter((percent): percent is number => percent !== undefined);
    expect(new Set(percents).size).toBe(percents.length);
  });
});

describe("advanceDemoGrid", () => {
  it("advances running agents only, leaving every other bucket alone", () => {
    const before = demoGrid();
    const after = advanceDemoGrid(before, 5);
    after.agents.forEach((agent, index) => {
      const previous = before.agents[index];
      const expected =
        previous.bucket === "running" ? ((previous.progress_percent as number) + 5) % 101 : previous.progress_percent;
      expect(agent.progress_percent, `agent ${String(previous.identifier)}`).toBe(expected);
    });
  });

  // A tick that walked past 100 would drive the progress bar off the key and
  // the percent label into nonsense, so it has to wrap.
  it("wraps a running agent's progress at 100", () => {
    const grid = { ...demoGrid(), agents: [{ identifier: "1", bucket: "running", progress_percent: 99 }] };
    expect(advanceDemoGrid(grid, 5).agents[0].progress_percent).toBe(3);
  });

  it("leaves the rest of the payload untouched", () => {
    const before = demoGrid();
    const after = advanceDemoGrid(before, 7);
    expect(after.total).toBe(before.total);
    expect(after.max_column_offset).toBe(before.max_column_offset);
    expect(after.agents).toHaveLength(before.agents.length);
  });
});
