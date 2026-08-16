import { describe, expect, it, vi } from "vitest";

import type { ChildLike, SpawnLike } from "../src/line-source.js";
import { createUdevSource, parseUdevBlock } from "../src/udev-source.js";

describe("parseUdevBlock", () => {
  it("returns device-added for a matching add block", () => {
    expect(parseUdevBlock(["ACTION=add", "DEVTYPE=usb_device", "ID_VENDOR_ID=0fd9"])).toBe("device-added");
  });

  it("returns device-removed for a matching remove block", () => {
    expect(parseUdevBlock(["ACTION=remove", "DEVTYPE=usb_device", "ID_VENDOR_ID=0fd9"])).toBe("device-removed");
  });

  it("matches the vendor case-insensitively", () => {
    expect(parseUdevBlock(["ACTION=add", "DEVTYPE=usb_device", "ID_VENDOR_ID=0FD9"])).toBe("device-added");
  });

  // Driver binding is not hotplug. Opening the deck through libusb detaches
  // hidraw and closing it lets the kernel rebind, and each of those emits a
  // hidraw add/remove carrying our vendor. Treating them as hotplug made a
  // single close feed itself an "add", which reopened, which emitted a
  // "remove" — roughly eight open/close cycles a second, with every buffered
  // input report discarded on the way through.
  it("ignores hidraw bind and unbind churn for our own device", () => {
    expect(parseUdevBlock(["ACTION=add", "SUBSYSTEM=hidraw", "HID_ID=0003:00000FD9:00000084"])).toBeNull();
    expect(parseUdevBlock(["ACTION=remove", "SUBSYSTEM=hidraw", "HID_ID=0003:00000fd9:00000084"])).toBeNull();
  });

  it("ignores an interface-level usb event", () => {
    expect(parseUdevBlock(["ACTION=add", "DEVTYPE=usb_interface", "ID_VENDOR_ID=0fd9"])).toBeNull();
  });

  it("ignores a usb block with no DEVTYPE at all", () => {
    expect(parseUdevBlock(["ACTION=add", "ID_VENDOR_ID=0fd9"])).toBeNull();
  });

  it("tolerates a trailing CR on property values", () => {
    expect(parseUdevBlock(["ACTION=add\r", "DEVTYPE=usb_device\r", "ID_VENDOR_ID=0fd9\r"])).toBe("device-added");
  });

  it("ignores a different vendor", () => {
    expect(parseUdevBlock(["ACTION=add", "DEVTYPE=usb_device", "ID_VENDOR_ID=1234"])).toBeNull();
  });

  it("ignores a non add/remove action for our vendor", () => {
    expect(parseUdevBlock(["ACTION=change", "DEVTYPE=usb_device", "ID_VENDOR_ID=0fd9"])).toBeNull();
  });

  it("ignores lines that are not KEY=VALUE and blocks with no vendor", () => {
    expect(parseUdevBlock(["UDEV header line", "=leadingequals"])).toBeNull();
  });
});

const fakeChild = (): { child: ChildLike; emitData: (chunk: string) => void } => {
  const dataListeners: ((chunk: string) => void)[] = [];
  return {
    child: {
      stdout: { setEncoding: vi.fn(), on: (_e, l) => dataListeners.push(l) },
      on: vi.fn(),
      kill: vi.fn(),
    },
    emitData: (chunk) => dataListeners.forEach((l) => l(chunk)),
  };
};

describe("createUdevSource", () => {
  it("flushes blocks on blank lines and dispatches add/remove", () => {
    const { child, emitData } = fakeChild();
    const spawn: SpawnLike = vi.fn(() => child);
    const onAdded = vi.fn();
    const onRemoved = vi.fn();
    createUdevSource(spawn, { onAdded, onRemoved });

    emitData("ACTION=add\nDEVTYPE=usb_device\nID_VENDOR_ID=0fd9\n\n");
    emitData("ACTION=remove\nDEVTYPE=usb_device\nID_VENDOR_ID=0fd9\n\n");
    // A blank line with no accumulated block is a no-op.
    emitData("\n");

    expect(onAdded).toHaveBeenCalledOnce();
    expect(onRemoved).toHaveBeenCalledOnce();
  });

  it("does not dispatch for an unrelated device block", () => {
    const { child, emitData } = fakeChild();
    const onAdded = vi.fn();
    const onRemoved = vi.fn();
    createUdevSource(vi.fn(() => child), { onAdded, onRemoved });

    emitData("ACTION=add\nDEVTYPE=usb_device\nID_VENDOR_ID=abcd\n\n");

    expect(onAdded).not.toHaveBeenCalled();
    expect(onRemoved).not.toHaveBeenCalled();
  });
});
