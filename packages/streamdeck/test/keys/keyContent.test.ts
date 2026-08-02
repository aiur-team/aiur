import { describe, expect, it } from "vitest";

import {
  type KeyContent,
  buildContentReports,
  cloneContent,
  contentEquals,
} from "../../src/keys/keyContent.js";

const fill = (r: number, g: number, b: number): KeyContent => ({ kind: "fill", color: { r, g, b } });
const image = (bytes: number[]): KeyContent => ({ kind: "image", jpeg: new Uint8Array(bytes) });

describe("key content identity", () => {
  it("compares fills by channel", () => {
    expect(contentEquals(fill(1, 2, 3), fill(1, 2, 3))).toBe(true);
    expect(contentEquals(fill(1, 2, 3), fill(1, 2, 4))).toBe(false);
  });

  it("compares images by bytes, including length", () => {
    expect(contentEquals(image([1, 2, 3]), image([1, 2, 3]))).toBe(true);
    expect(contentEquals(image([1, 2, 3]), image([1, 2, 4]))).toBe(false);
    expect(contentEquals(image([1, 2, 3]), image([1, 2]))).toBe(false);
  });

  it("treats a fill and an image as never equal, both directions", () => {
    expect(contentEquals(fill(0, 0, 0), image([0]))).toBe(false);
    expect(contentEquals(image([0]), fill(0, 0, 0))).toBe(false);
  });
});

describe("cloneContent", () => {
  it("deep-copies a fill so later mutation cannot alias", () => {
    const original = { kind: "fill", color: { r: 1, g: 2, b: 3 } } as const;
    const copy = cloneContent(original);
    expect(copy).toEqual(original);
    expect(copy === original).toBe(false);
  });

  it("copies image bytes defensively", () => {
    const bytes = new Uint8Array([9, 8, 7]);
    const copy = cloneContent({ kind: "image", jpeg: bytes });
    bytes[0] = 0;
    expect(copy.kind === "image" && [...copy.jpeg]).toEqual([9, 8, 7]);
  });
});

describe("buildContentReports", () => {
  it("builds one feature report for a fill", () => {
    const reports = buildContentReports(1, fill(4, 5, 6), "raw");
    expect(reports).toHaveLength(1);
    expect(reports[0].kind).toBe("feature"); // routes to sendFeatureReport()
    expect(reports[0].data).toHaveLength(32);
    expect(reports[0].data.readUInt8(1)).toBe(0x06);
  });

  it("builds the 0x07 chunk sequence of output reports for an image", () => {
    const reports = buildContentReports(1, image([1, 2, 3]), "raw");
    expect(reports).toHaveLength(1);
    expect(reports[0].kind).toBe("output"); // routes to hid.write()
    expect(reports[0].data).toHaveLength(1024);
    expect(reports[0].data.readUInt8(1)).toBe(0x07);
  });
});
