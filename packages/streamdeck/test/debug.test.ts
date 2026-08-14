import { describe, expect, it } from "vitest";

import { createDebugLog, debugEnabled, hexPreview } from "../src/debug.js";

describe("debugEnabled", () => {
  it("is off unless explicitly requested", () => {
    expect(debugEnabled(undefined)).toBe(false);
    expect(debugEnabled("")).toBe(false);
    expect(debugEnabled("0")).toBe(false);
    expect(debugEnabled("no")).toBe(false);
  });

  it("accepts the documented truthy spellings", () => {
    expect(debugEnabled("1")).toBe(true);
    expect(debugEnabled("true")).toBe(true);
  });
});

describe("createDebugLog", () => {
  it("writes nothing when disabled", () => {
    const lines: string[] = [];
    createDebugLog(false, (line) => lines.push(line))("input.report", { length: 512 });
    expect(lines).toEqual([]);
  });

  it("formats a channel with its detail fields", () => {
    const lines: string[] = [];
    createDebugLog(true, (line) => lines.push(line))("input.report", { length: 512, bytes: "01 00" });
    expect(lines).toEqual(["[streamdeck:debug] input.report length=512 bytes=01 00"]);
  });

  it("writes a bare channel when there is no detail", () => {
    const lines: string[] = [];
    createDebugLog(true, (line) => lines.push(line))("input.pollStarted");
    expect(lines).toEqual(["[streamdeck:debug] input.pollStarted"]);
  });
});

describe("hexPreview", () => {
  it("renders every byte of a short report", () => {
    expect(hexPreview(Uint8Array.from([0x01, 0x00, 0x08, 0xff]))).toBe("01 00 08 ff");
  });

  // A 512-byte report is mostly zero padding; the trace must stay one line.
  it("elides a long report and reports its true length", () => {
    const report = new Uint8Array(512);
    report[0] = 0x01;
    expect(hexPreview(report, 4)).toBe("01 00 00 00 …(512B)");
  });
});
