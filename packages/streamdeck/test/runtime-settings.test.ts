import { afterEach, expect, it, vi } from "vitest";
import { startRuntime } from "../src/runtime.js";
import type { RawRead } from "../src/read.js";
import type { NetLike, NetServerLike } from "../src/lock.js";
const settle = async () => { for (let n = 0; n < 30; n++) await Promise.resolve(); };
afterEach(() => vi.useRealTimers());
it("applies daemon brightness and wakes on a real runtime input report", async () => {
  vi.useFakeTimers();
  let deliver!: (value: RawRead) => void;
  const writes = vi.fn<(data: Uint8Array) => Promise<void>>(async () => undefined);
  const input = vi.fn();
  const net: NetLike = { createServer: (): NetServerLike => {
    const handlers = new Map<string, (value?: unknown) => void>();
    return { once: (key, fn) => handlers.set(key, fn), removeListener: (key) => handlers.delete(key), listen: () => handlers.get("listening")?.(), close: vi.fn() };
  } };
  const runtime = await startRuntime({
    net, spawn: () => ({ stdout: null, on: vi.fn(), kill: vi.fn() }),
    brightness: 80, devicePresentAtStart: true, registerSignals: vi.fn(), exit: vi.fn(), log: vi.fn(), onBackendClosed: vi.fn(),
    setTimer: setTimeout, clearTimer: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>), onInput: input,
    openBackend: async () => ({ write: async () => undefined, read: () => new Promise<RawRead>((resolve) => { deliver = resolve; }), sendFeatureReport: writes, getFeatureReport: async () => new Uint8Array(), close: async () => undefined }),
  });
  await settle();
  runtime.applySettings({ brightness: 30, dim_after_seconds: 5 });
  expect(writes.mock.calls.at(-1)?.[0][2]).toBe(30);
  await vi.advanceTimersByTimeAsync(4999);
  expect(writes.mock.calls.at(-1)?.[0][2]).toBe(30);
  await vi.advanceTimersByTimeAsync(1);
  expect(writes.mock.calls.at(-1)?.[0][2]).toBe(0);
  const report = Uint8Array.from([1, 0, 0, 0, 1]);
  deliver({ kind: "bytes", data: report });
  await settle();
  expect(input).toHaveBeenCalledWith(report);
  expect(writes.mock.calls.at(-1)?.[0][2]).toBe(30);
  runtime.stop();
});
