import { describe, expect, it, vi } from "vitest";

import { findStreamDeckPath, hidId, parseBrightness, type DevicePathFs } from "../src/device-path.js";
import { PRODUCT_ID, VENDOR_ID } from "../src/report.js";

const WANTED = hidId(VENDOR_ID, PRODUCT_ID);

describe("hidId", () => {
  it("formats the sysfs HID_ID token for the Stream Deck +", () => {
    expect(WANTED).toBe("00000FD9:00000084");
  });
});

describe("findStreamDeckPath", () => {
  const fsWith = (nodes: string[], uevents: Record<string, string>): DevicePathFs => ({
    readdir: vi.fn(async () => nodes),
    readFile: vi.fn(async (path: string) => {
      const node = path.split("/")[4];
      const content = uevents[node];
      if (content === undefined) {
        throw new Error("ENOENT");
      }
      return content;
    }),
  });

  it("returns the node whose uevent matches, skipping non-matching ones", async () => {
    const fs = fsWith(["hidraw0", "hidraw7"], {
      hidraw0: "HID_ID=0003:0000ABCD:00001234",
      hidraw7: `HID_ID=0003:${WANTED}`,
    });
    expect(await findStreamDeckPath(fs)).toBe("/dev/hidraw7");
  });

  it("matches case-insensitively", async () => {
    const fs = fsWith(["hidraw3"], { hidraw3: `hid_id=0003:${WANTED.toLowerCase()}` });
    expect(await findStreamDeckPath(fs)).toBe("/dev/hidraw3");
  });

  it("returns null when no node matches", async () => {
    const fs = fsWith(["hidraw0"], { hidraw0: "HID_ID=0003:0000ABCD:00001234" });
    expect(await findStreamDeckPath(fs)).toBeNull();
  });

  it("treats an unreadable uevent as a non-match", async () => {
    const fs = fsWith(["hidraw0"], {}); // readFile throws for every node
    expect(await findStreamDeckPath(fs)).toBeNull();
  });

  it("treats an unreadable class directory as absent", async () => {
    const fs: DevicePathFs = {
      readdir: vi.fn(async () => {
        throw new Error("EACCES");
      }),
      readFile: vi.fn(async () => ""),
    };
    expect(await findStreamDeckPath(fs)).toBeNull();
  });
});

describe("parseBrightness", () => {
  it("parses a numeric value", () => {
    expect(parseBrightness("60")).toBe(60);
  });

  it("falls back to the default when unset or non-numeric", () => {
    expect(parseBrightness(undefined)).toBe(80);
    expect(parseBrightness("bright")).toBe(80);
    expect(parseBrightness("nope", 25)).toBe(25);
  });
});
