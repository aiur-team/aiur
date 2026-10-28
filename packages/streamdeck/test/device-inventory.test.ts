import { afterEach, expect, it, vi } from "vitest";
import { createDeviceInventory } from "../src/device-inventory.js";
import type { ChildLike } from "../src/line-source.js";
afterEach(() => vi.useRealTimers());
it("reports joined inventory, refreshes on audio changes, and restarts the monitor", async () => {
  vi.useFakeTimers();
  let data!: (value: string) => void;
  const ends: (() => void)[] = [];
  const kill = vi.fn();
  const spawn = vi.fn((): ChildLike => ({ stdout: { setEncoding: vi.fn(), on: (_event, fn) => { data = fn; } }, on: (_event, fn) => { ends.push(fn); }, kill }));
  const changed = vi.fn();
  let raw = JSON.stringify([{ info: { props: { "media.class": "Audio/Source", "node.name": "mic" } } }]);
  const system = { run: vi.fn(async () => raw), spawn: vi.fn() };
  const inventory = createDeviceInventory({ system, spawn, instances: ["local"], legacyMicId: "remembered", changed, setTimer: setTimeout, clearTimer: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>) });
  await inventory.refresh();
  expect(changed).toHaveBeenLastCalledWith({ mics: [{ id: "mic", label: "mic" }], speakers: [], instances: ["local"], legacy_mic_id: "remembered" });
  raw = "[]";
  data("Event 'remove' on source #1\n");
  await vi.advanceTimersByTimeAsync(0);
  expect(changed).toHaveBeenLastCalledWith({ mics: [], speakers: [], instances: ["local"], legacy_mic_id: "remembered" });
  const count = changed.mock.calls.length;
  data("Event 'change' on client #1\n");
  expect(changed).toHaveBeenCalledTimes(count);
  ends[0]!(); ends[1]!();
  await vi.advanceTimersByTimeAsync(5000);
  expect(spawn).toHaveBeenCalledTimes(2);
  inventory.stop();
  expect(kill).toHaveBeenCalled();
  const afterStop = changed.mock.calls.length;
  await inventory.refresh();
  expect(changed).toHaveBeenCalledTimes(afterStop);
});

it("coalesces simultaneous refreshes and drops an enumeration finishing after stop", async () => {
  let resolve!: (raw: string) => void;
  let first = true;
  const run = vi.fn(() => {
    if (first) { first = false; return new Promise<string>((done) => { resolve = done; }); }
    return Promise.resolve("[]");
  });
  const changed = vi.fn();
  const ends: (() => void)[] = [];
  const timers = new Map<number, () => void>();
  const inventory = createDeviceInventory({
    system: { run, spawn: vi.fn() }, spawn: () => ({ stdout: null, on: (_event, fn) => { ends.push(fn); }, kill: vi.fn() }),
    instances: [], legacyMicId: null, changed,
    setTimer: (fn) => { timers.set(1, fn); return 1; }, clearTimer: (id) => timers.delete(id as number),
  });
  const pending = inventory.refresh();
  await inventory.refresh();
  resolve("[]");
  await pending;
  expect(changed.mock.calls).toEqual([[{ mics: [], speakers: [], instances: [] }], [{ mics: [], speakers: [], instances: [] }]]);
  ends[0]!();
  expect(timers.size).toBe(1);
  inventory.stop();
  expect(timers.size).toBe(0);
  ends[1]!();
  expect(timers.size).toBe(0);
});

it("never publishes devices after its owner disconnects during discovery", async () => {
  let resolve!: (raw: string) => void;
  const pending = new Promise<string>((done) => { resolve = done; });
  const changed = vi.fn();
  const inventory = createDeviceInventory({ system: { run: () => pending, spawn: vi.fn() }, spawn: () => ({ stdout: null, on: vi.fn(), kill: vi.fn() }), instances: [], legacyMicId: null, changed, setTimer: vi.fn(), clearTimer: vi.fn() });
  const refreshing = inventory.refresh();
  inventory.stop();
  resolve("[]");
  await refreshing;
  expect(changed).not.toHaveBeenCalled();
});
