import { describe, expect, it } from "vitest";

import { classifyRead } from "../src/read.js";
import { INPUT_REPORT_LENGTH, MIN_INPUT_REPORT_LENGTH } from "../src/report.js";

describe("classifyRead", () => {
  it("treats a timeout as idle, never a disconnect", () => {
    expect(classifyRead({ kind: "timeout" })).toEqual({ type: "idle" });
  });

  it("treats an undecodable runt as idle", () => {
    expect(classifyRead({ kind: "bytes", data: new Uint8Array(MIN_INPUT_REPORT_LENGTH - 1) })).toEqual({ type: "idle" });
  });

  it("returns a full-length device report as input", () => {
    const data = new Uint8Array(INPUT_REPORT_LENGTH);
    data[0] = 0x01;
    expect(classifyRead({ kind: "bytes", data })).toEqual({ type: "input", data });
  });

  // The device pads every event to INPUT_REPORT_LENGTH, but the classifier must
  // not require the full length: gating on it is the kind of over-strict check
  // that silently swallows real input as an idle poll.
  it("returns a decodable short report as input rather than idle", () => {
    const data = new Uint8Array(MIN_INPUT_REPORT_LENGTH);
    data[0] = 0x01;
    expect(classifyRead({ kind: "bytes", data })).toEqual({ type: "input", data });
  });

  it("surfaces a genuine read failure as error", () => {
    const error = new Error("boom");
    expect(classifyRead({ kind: "error", error })).toEqual({ type: "error", error });
  });
});
