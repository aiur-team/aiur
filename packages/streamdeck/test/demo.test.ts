import { describe, expect, it } from "vitest";

import { createPhysicalController } from "../src/controller.js";
import { demoGrid, demoLogs } from "../src/demo.js";
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
