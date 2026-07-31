import { describe, expect, it } from "vitest";

import { classifyRead } from "../src/read.js";
import { READ_LENGTH } from "../src/report.js";

describe("classifyRead", () => {
  it("treats a timeout as idle, never a disconnect", () => {
    expect(classifyRead({ kind: "timeout" })).toEqual({ type: "idle" });
  });

  it("treats a short buffer as idle", () => {
    expect(classifyRead({ kind: "bytes", data: new Uint8Array(READ_LENGTH - 1) })).toEqual({ type: "idle" });
  });

  it("returns a full-length buffer as input", () => {
    const data = new Uint8Array(READ_LENGTH);
    data[0] = 0x01;
    expect(classifyRead({ kind: "bytes", data })).toEqual({ type: "input", data });
  });

  it("surfaces a genuine read failure as error", () => {
    const error = new Error("boom");
    expect(classifyRead({ kind: "error", error })).toEqual({ type: "error", error });
  });
});
