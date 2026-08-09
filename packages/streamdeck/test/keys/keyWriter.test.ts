import { describe, expect, it, vi } from "vitest";

import { createKeyReportWriter } from "../../src/keys/keyWriter.js";

describe("createKeyReportWriter", () => {
  it("routes output JPEG reports to the interrupt writer", async () => {
    const backend = {
      write: vi.fn(async () => {}),
      sendFeatureReport: vi.fn(async () => {}),
    };
    const runtime = { notifyWriteFailure: vi.fn() };

    await createKeyReportWriter(backend, runtime)({ kind: "output", data: Buffer.from([0x02, 0x07]) });

    expect(backend.write).toHaveBeenCalledWith(Buffer.from([0x02, 0x07]));
    expect(backend.sendFeatureReport).not.toHaveBeenCalled();
    expect(runtime.notifyWriteFailure).not.toHaveBeenCalled();
  });

  it("routes RGB fills to the feature writer", async () => {
    const backend = {
      write: vi.fn(async () => {}),
      sendFeatureReport: vi.fn(async () => {}),
    };
    const runtime = { notifyWriteFailure: vi.fn() };

    await createKeyReportWriter(backend, runtime)({ kind: "feature", data: Buffer.from([0x03, 0x06]) });

    expect(backend.write).not.toHaveBeenCalled();
    expect(backend.sendFeatureReport).toHaveBeenCalledWith(Buffer.from([0x03, 0x06]));
    expect(runtime.notifyWriteFailure).not.toHaveBeenCalled();
  });

  it("reports and rethrows an output write failure", async () => {
    const error = new Error("zombie handle");
    const backend = {
      write: vi.fn(async () => {
        throw error;
      }),
      sendFeatureReport: vi.fn(async () => {}),
    };
    const runtime = { notifyWriteFailure: vi.fn() };

    await expect(
      createKeyReportWriter(backend, runtime)({ kind: "output", data: Buffer.from([0x02, 0x07]) }),
    ).rejects.toBe(error);

    expect(runtime.notifyWriteFailure).toHaveBeenCalledWith(error);
  });

  it("reports and rethrows a feature write failure", async () => {
    const error = new Error("feature failed");
    const backend = {
      write: vi.fn(async () => {}),
      sendFeatureReport: vi.fn(async () => {
        throw error;
      }),
    };
    const runtime = { notifyWriteFailure: vi.fn() };

    await expect(
      createKeyReportWriter(backend, runtime)({ kind: "feature", data: Buffer.from([0x03, 0x06]) }),
    ).rejects.toBe(error);

    expect(runtime.notifyWriteFailure).toHaveBeenCalledWith(error);
  });

  it("does not let a broken notifier mask the transfer failure", async () => {
    const error = new Error("EIO");
    const backend = {
      write: vi.fn(async () => {
        throw error;
      }),
      sendFeatureReport: vi.fn(async () => {}),
    };
    const runtime = {
      notifyWriteFailure: vi.fn(() => {
        throw new Error("recovery dispatch failed");
      }),
    };

    await expect(
      createKeyReportWriter(backend, runtime)({ kind: "output", data: Buffer.from([0x02, 0x07]) }),
    ).rejects.toBe(error);

    expect(runtime.notifyWriteFailure).toHaveBeenCalledWith(error);
  });
});
