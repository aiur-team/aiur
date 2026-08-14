/**
 * hidraw transport backend over `node:fs`.
 *
 * Opens `/dev/hidrawN` non-blocking and speaks the parts of the HID protocol
 * that plain file I/O can: OUTPUT reports via `write`, INPUT reports via a
 * non-blocking `read` whose `EAGAIN` (no event pending) is reported as a
 * timeout — the reducer treats that as idle, never a disconnect
 * ({@link file://./read.ts}).
 *
 * It deliberately does **not** implement FEATURE reports. Brightness, Show
 * Logo/reset, serial, and firmware are feature reports, which require the
 * `HIDIOCSFEATURE`/`HIDIOCGFEATURE` ioctls; `node:fs` cannot issue ioctls, so
 * those methods throw {@link FeatureReportsUnsupportedError}. Per the ticket:
 * if a host needs feature reports, use a libusb-backed handle instead — the
 * {@link HidBackend} interface is identical, so only the constructor changes.
 *
 * The `fs` primitive is injected so this is testable against a fake handle and
 * never opens a real device under test.
 */

import type { HidBackend } from "./backend.js";
import type { RawRead } from "./read.js";
import { INPUT_REPORT_LENGTH } from "./report.js";

/** `O_RDWR | O_NONBLOCK` — the flags the backend opens the node with. */
export const HIDRAW_OPEN_FLAGS = 0x0002 | 0x0800;

/** Minimal open file handle surface the backend uses. */
export interface FileHandleLike {
  read(
    buffer: Uint8Array,
    offset: number,
    length: number,
    position: number | null,
  ): Promise<{ bytesRead: number }>;
  write(buffer: Uint8Array): Promise<unknown>;
  close(): Promise<void>;
}

/** Minimal `node:fs/promises` surface the backend uses. */
export interface FsLike {
  open(path: string, flags: number): Promise<FileHandleLike>;
}

/** Thrown by the feature-report methods of the fs backend. */
export class FeatureReportsUnsupportedError extends Error {
  constructor(operation: string) {
    super(
      `The hidraw fs backend cannot ${operation}: feature reports require the ` +
        `HIDIOCSFEATURE/HIDIOCGFEATURE ioctls, which node:fs cannot issue. Use a ` +
        `libusb-backed handle for brightness, reset/Show Logo, serial, and firmware.`,
    );
    this.name = "FeatureReportsUnsupportedError";
  }
}

const isTryAgain = (error: unknown): boolean => {
  const code = (error as { code?: unknown } | null)?.code;
  return code === "EAGAIN" || code === "EWOULDBLOCK";
};

/**
 * Opens `path` and returns a backend bound to it. Rejects if the node cannot be
 * opened (absent device, missing udev ACL), which surfaces as a clear error to
 * the caller.
 */
export const openHidrawBackend = async (fs: FsLike, path: string): Promise<HidBackend> => {
  const handle = await fs.open(path, HIDRAW_OPEN_FLAGS);

  return {
    write: async (report) => {
      await handle.write(report);
    },

    read: async (): Promise<RawRead> => {
      const buffer = new Uint8Array(INPUT_REPORT_LENGTH);
      try {
        const { bytesRead } = await handle.read(buffer, 0, INPUT_REPORT_LENGTH, null);
        if (bytesRead === 0) {
          return { kind: "timeout" };
        }
        return { kind: "bytes", data: buffer.subarray(0, bytesRead) };
      } catch (error) {
        if (isTryAgain(error)) {
          return { kind: "timeout" };
        }
        return { kind: "error", error };
      }
    },

    sendFeatureReport: async () => {
      throw new FeatureReportsUnsupportedError("send a feature report");
    },

    getFeatureReport: async () => {
      throw new FeatureReportsUnsupportedError("read a feature report");
    },

    close: () => handle.close(),
  };
};
