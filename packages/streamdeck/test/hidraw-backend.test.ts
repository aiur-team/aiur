import { describe, expect, it, vi } from "vitest";

import { FeatureReportsUnsupportedError, HIDRAW_OPEN_FLAGS, openHidrawBackend, type FileHandleLike, type FsLike } from "../src/hidraw-backend.js";
import { READ_LENGTH } from "../src/report.js";

const fakeFs = (handle: Partial<FileHandleLike>): { fs: FsLike; open: ReturnType<typeof vi.fn> } => {
  const full: FileHandleLike = {
    read: vi.fn(async () => ({ bytesRead: 0 })),
    write: vi.fn(async () => undefined),
    close: vi.fn(async () => undefined),
    ...handle,
  };
  const open = vi.fn(async () => full);
  return { fs: { open }, open };
};

describe("openHidrawBackend", () => {
  it("opens the node non-blocking and writes output reports", async () => {
    const write = vi.fn(async () => undefined);
    const { fs, open } = fakeFs({ write });
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");

    expect(open).toHaveBeenCalledWith("/dev/hidraw9", HIDRAW_OPEN_FLAGS);
    const report = new Uint8Array([1, 2, 3]);
    await backend.write(report);
    expect(write).toHaveBeenCalledWith(report);
  });

  it("reports bytes as a trimmed buffer", async () => {
    const { fs } = fakeFs({
      read: vi.fn(async (buffer: Uint8Array) => {
        buffer[0] = 7;
        return { bytesRead: READ_LENGTH };
      }),
    });
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");
    const result = await backend.read();
    expect(result).toEqual({ kind: "bytes", data: expect.any(Uint8Array) });
    expect(result.kind === "bytes" && result.data[0]).toBe(7);
  });

  it("maps a zero-length read to a timeout", async () => {
    const { fs } = fakeFs({ read: vi.fn(async () => ({ bytesRead: 0 })) });
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");
    expect(await backend.read()).toEqual({ kind: "timeout" });
  });

  it("maps EAGAIN and EWOULDBLOCK to a timeout", async () => {
    for (const code of ["EAGAIN", "EWOULDBLOCK"]) {
      const { fs } = fakeFs({
        read: vi.fn(async () => {
          throw Object.assign(new Error("try again"), { code });
        }),
      });
      const backend = await openHidrawBackend(fs, "/dev/hidraw9");
      expect(await backend.read()).toEqual({ kind: "timeout" });
    }
  });

  it("surfaces any other read failure as an error", async () => {
    const failure = Object.assign(new Error("io"), { code: "EIO" });
    const { fs } = fakeFs({
      read: vi.fn(async () => {
        throw failure;
      }),
    });
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");
    expect(await backend.read()).toEqual({ kind: "error", error: failure });
  });

  it("refuses feature reports and documents the libusb requirement", async () => {
    const { fs } = fakeFs({});
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");

    await expect(backend.sendFeatureReport(new Uint8Array(1))).rejects.toBeInstanceOf(FeatureReportsUnsupportedError);
    await expect(backend.getFeatureReport(0x06, 32)).rejects.toThrow(/libusb/);
  });

  it("closes the handle", async () => {
    const close = vi.fn(async () => undefined);
    const { fs } = fakeFs({ close });
    const backend = await openHidrawBackend(fs, "/dev/hidraw9");
    await backend.close();
    expect(close).toHaveBeenCalledOnce();
  });
});
