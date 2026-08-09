import { describe, expect, it, vi } from "vitest";

import { openUsbBackend, type UsbDeviceLike, type UsbInResult } from "../src/usb-backend.js";

const makeDevice = (overrides: Partial<UsbDeviceLike> = {}): UsbDeviceLike => ({
  claim: vi.fn(async () => undefined),
  controlOut: vi.fn(async () => undefined),
  controlIn: vi.fn(async () => new Uint8Array()),
  transferOut: vi.fn(async () => undefined),
  transferIn: vi.fn(async (): Promise<UsbInResult> => ({ timedOut: true })),
  close: vi.fn(async () => undefined),
  ...overrides,
});

// USB HID class-request constants asserted against (see usb-backend.ts header).
const SET_REPORT = { bmRequestType: 0x21, bRequest: 0x09 };
const GET_REPORT = { bmRequestType: 0xa1, bRequest: 0x01 };
const featureValue = (id: number): number => (0x03 << 8) | id;

describe("openUsbBackend", () => {
  it("claims the interface on open", async () => {
    const device = makeDevice();
    await openUsbBackend(device);
    expect(device.claim).toHaveBeenCalledOnce();
  });

  it("propagates a claim failure", async () => {
    const device = makeDevice({ claim: vi.fn(async () => Promise.reject(new Error("EBUSY"))) });
    await expect(openUsbBackend(device)).rejects.toThrow(/EBUSY/);
  });

  it("writes OUTPUT reports over the interrupt-out endpoint", async () => {
    const device = makeDevice();
    const backend = await openUsbBackend(device);
    const report = Uint8Array.from([0x02, 0x00, 0x01]);
    await backend.write(report);
    expect(device.transferOut).toHaveBeenCalledWith(report);
  });

  it("maps a poll timeout to a timeout read", async () => {
    const device = makeDevice({ transferIn: vi.fn(async (): Promise<UsbInResult> => ({ timedOut: true })) });
    const backend = await openUsbBackend(device);
    expect(await backend.read()).toEqual({ kind: "timeout" });
  });

  it("returns received bytes as an input read", async () => {
    const data = Uint8Array.from([1, 2, 3]);
    const device = makeDevice({ transferIn: vi.fn(async (): Promise<UsbInResult> => ({ timedOut: false, data })) });
    const backend = await openUsbBackend(device);
    expect(await backend.read()).toEqual({ kind: "bytes", data });
  });

  it("maps a genuine transfer failure to an error read", async () => {
    const boom = new Error("EIO");
    const device = makeDevice({ transferIn: vi.fn(async () => Promise.reject(boom)) });
    const backend = await openUsbBackend(device);
    expect(await backend.read()).toEqual({ kind: "error", error: boom });
  });

  it("sends a feature report as a SET_REPORT control transfer on the default interface", async () => {
    const device = makeDevice();
    const backend = await openUsbBackend(device);
    const report = Uint8Array.from([0x03, 0x08, 60]);
    await backend.sendFeatureReport(report);
    expect(device.controlOut).toHaveBeenCalledWith(
      SET_REPORT.bmRequestType,
      SET_REPORT.bRequest,
      featureValue(0x03),
      0,
      report,
    );
  });

  it("reads a feature report as a GET_REPORT control transfer", async () => {
    const answer = Uint8Array.from([0x06, 0x41, 0x42]);
    const device = makeDevice({ controlIn: vi.fn(async () => answer) });
    const backend = await openUsbBackend(device);
    const result = await backend.getFeatureReport(0x06, 32);
    expect(device.controlIn).toHaveBeenCalledWith(
      GET_REPORT.bmRequestType,
      GET_REPORT.bRequest,
      featureValue(0x06),
      0,
      32,
    );
    expect(result).toBe(answer);
  });

  it("targets the configured interface number", async () => {
    const device = makeDevice();
    const backend = await openUsbBackend(device, { interfaceNumber: 2 });
    await backend.sendFeatureReport(Uint8Array.from([0x03, 0x02]));
    expect(device.controlOut).toHaveBeenCalledWith(SET_REPORT.bmRequestType, SET_REPORT.bRequest, featureValue(0x03), 2, expect.any(Uint8Array));
  });

  it("defaults the report id to 0 for an empty feature report", async () => {
    const device = makeDevice();
    const backend = await openUsbBackend(device);
    await backend.sendFeatureReport(new Uint8Array(0));
    expect(device.controlOut).toHaveBeenCalledWith(SET_REPORT.bmRequestType, SET_REPORT.bRequest, featureValue(0), 0, expect.any(Uint8Array));
  });

  it("closes the underlying device", async () => {
    const device = makeDevice();
    const backend = await openUsbBackend(device);
    await backend.close();
    expect(device.close).toHaveBeenCalledOnce();
  });
});
