import { describe, it, expect, vi } from "vitest";
import { GlobalFonts } from "@napi-rs/canvas";
import { FrameRenderer, offlineFrame, registerFrameFont, type DeckFrame } from "../src/frame.js";
import type { HidBackend } from "../src/backend.js";

const svg = (color: string) => `<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120"><rect width="120" height="120" fill="${color}"/></svg>`;
const frame = (color = "red"): DeckFrame => ({ keys: [{ svg: svg(color), hash: color }, ...Array(7).fill(null)], strip: [{ x: 0, width: 800, svg: svg(color), hash: color }] });
const backend = () => {
  const writes: Buffer[] = [];
  const features: Buffer[] = [];
  return { writes, features, write: vi.fn(async (data: Uint8Array) => { writes.push(Buffer.from(data)); }), sendFeatureReport: vi.fn(async (data: Uint8Array) => { features.push(Buffer.from(data)); }) };
};
const apply = (renderer: FrameRenderer, device: ReturnType<typeof backend>, data: DeckFrame) => renderer.apply(device as unknown as HidBackend, data);

describe("daemon frame rasterization", () => {
  it("writes real JPEG key reports at the requested index and black feature fills for nulls", async () => {
    registerFrameFont();
    const device = backend();
    await apply(new FrameRenderer(), device, frame());
    const keys = device.writes.filter((report) => report[1] === 7);
    expect(new Set(keys.map((report) => report[2]))).toEqual(new Set([0]));
    expect([...keys[0]!.subarray(8, 10)]).toEqual([255, 216]);
    expect(device.features.map((report) => [...report.subarray(0, 6)])).toEqual(Array.from({ length: 7 }, (_, i) => [3, 6, i + 1, 0, 0, 0]));
    const strip = device.writes.find((report) => report[1] === 12)!;
    expect([...strip.subarray(16, 18)]).toEqual([255, 216]);
    expect([strip.readUInt16LE(2), strip.readUInt16LE(4), strip.readUInt16LE(6), strip.readUInt16LE(8)]).toEqual([0, 0, 800, 100]);
  });

  it("skips unchanged hashes even if SVG differs, and writes just the changed region", async () => {
    const renderer = new FrameRenderer();
    const device = backend();
    const initial = frame();
    await apply(renderer, device, initial);
    device.writes.length = 0; device.features.length = 0;
    await apply(renderer, device, { ...initial, keys: [{ ...initial.keys[0]!, svg: svg("blue") }, ...initial.keys.slice(1)] });
    expect(device.writes).toEqual([]);
    expect(device.features).toEqual([]);
    await apply(renderer, device, { ...initial, strip: [{ x: 0, width: 800, svg: svg("blue"), hash: "blue" }] });
    const reports = device.writes;
    expect(reports.every((report) => report[1] === 12)).toBe(true);
    expect(reports.filter((report) => report.readUInt16LE(11) === 0)).toHaveLength(1);
    expect(reports.filter((report) => report[10] === 1)).toHaveLength(1);
  });

  it("replaces the strip layout, reuses JPEGs and invalidates on reconnect/reset", async () => {
    const renderer = new FrameRenderer(); const device = backend();
    await apply(renderer, device, frame());
    const split = { ...frame(), strip: [0, 400].map((x) => ({ x, width: 400, svg: svg("red"), hash: "red" })) };
    device.writes.length = 0;
    await apply(renderer, device, split);
    expect(new Set(device.writes.map((r) => r.readUInt16LE(2)))).toEqual(new Set([0, 400]));
    renderer.invalidate();
    await apply(renderer, device, split);
    const reopened = backend(); await apply(renderer, reopened, split);
    expect(reopened.features).toHaveLength(7);
    expect(reopened.writes.some((r) => r[1] === 7)).toBe(true);
    await apply(renderer, reopened, { ...split, keys: Array(8).fill(null) });
    expect([...reopened.features.at(-1)!.subarray(0, 6)]).toEqual([3, 6, 0, 0, 0, 0]);
  });

  it("recovers after key and strip write failures without caching unsent pixels", async () => {
    for (const phase of ["key", "strip"]) {
      const renderer = new FrameRenderer(); const device = backend();
      device.write.mockImplementationOnce(async () => { if (phase === "key") throw new Error("unplug"); });
      if (phase === "strip") device.sendFeatureReport.mockRejectedValueOnce(new Error("unplug"));
      await expect(apply(renderer, device, frame())).rejects.toThrow("unplug");
      await apply(renderer, device, frame());
      expect(device.writes.some((r) => r[1] === 7)).toBe(true);
      expect(device.features).toHaveLength(7);
    }
    const renderer = new FrameRenderer(); const device = backend();
    await apply(renderer, device, frame());
    device.write.mockRejectedValueOnce(new Error("strip unplug"));
    await expect(apply(renderer, device, frame("blue"))).rejects.toThrow();
    await apply(renderer, device, frame("blue"));
  });

  it("evicts the least recently used JPEG and suppresses equal encoded bytes", async () => {
    const renderer = new FrameRenderer(1); const device = backend();
    await apply(renderer, device, frame());
    await apply(renderer, device, frame("blue"));
    await apply(renderer, device, frame());
    device.writes.length = 0;
    await apply(renderer, device, { ...frame(), keys: [{ svg: svg("red"), hash: "another" }, ...Array(7).fill(null)], strip: [{ ...frame().strip[0]!, hash: "another" }] });
    expect(device.writes).toEqual([]);
  });

  it("rejects incomplete frames and malformed regions", async () => {
    const renderer = new FrameRenderer(); const device = backend();
    for (const data of [ { ...frame(), keys: [] }, { ...frame(), strip: [] }, { ...frame(), strip: [{ ...frame().strip[0]!, width: 799 }] }, ...[{ x: 1 }, { x: 0.5 }, { width: 0 }, { width: 1.5 }].map((patch) => ({ ...frame(), strip: [{ ...frame().strip[0]!, ...patch }] })) ]) {
      await expect(apply(renderer, device, data)).rejects.toThrow(/Frame/);
    }
    expect(device.writes).toEqual([]);
  });

  it("renders the bundled offline SVG and reports a missing font", async () => {
    const device = backend(); await apply(new FrameRenderer(), device, offlineFrame());
    expect(device.features).toHaveLength(8);
    expect(device.writes[0]![1]).toBe(12);
    const register = vi.spyOn(GlobalFonts, "registerFromPath").mockReturnValue(null);
    expect(registerFrameFont).toThrow("Cannot register");
    register.mockRestore();
  });
});
