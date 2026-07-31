import { describe, expect, it, vi } from "vitest";

import type { HidBackend } from "../src/backend.js";
import type { ChildLike } from "../src/line-source.js";
import type { NetLike, NetServerLike } from "../src/lock.js";
import type { RawRead } from "../src/read.js";
import { startRuntime, type LogEntry, type RuntimeEnv } from "../src/runtime.js";

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

const defer = <T>(): { promise: Promise<T>; resolve: (value: T) => void } => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
};

const okNet = (): NetLike => ({
  createServer: (): NetServerLike => {
    const listeners = new Map<string, (arg?: unknown) => void>();
    return {
      once: (event, listener) => listeners.set(event, listener),
      removeListener: (event) => listeners.delete(event),
      listen: () => listeners.get("listening")?.(),
      close: vi.fn(),
    };
  },
});

const busyNet = (): NetLike => ({
  createServer: (): NetServerLike => {
    const listeners = new Map<string, (arg?: unknown) => void>();
    return {
      once: (event, listener) => listeners.set(event, listener),
      removeListener: (event) => listeners.delete(event),
      listen: () => listeners.get("error")?.(Object.assign(new Error("busy"), { code: "EADDRINUSE" })),
      close: vi.fn(),
    };
  },
});

const makeBackend = (overrides: Partial<HidBackend> = {}): HidBackend => ({
  write: vi.fn(async () => undefined),
  read: vi.fn(async (): Promise<RawRead> => ({ kind: "timeout" })),
  sendFeatureReport: vi.fn(async () => undefined),
  getFeatureReport: vi.fn(async () => new Uint8Array()),
  close: vi.fn(async () => undefined),
  ...overrides,
});

interface Harness {
  env: RuntimeEnv;
  logs: LogEntry[];
  signal(): void;
  udev: { onAdded(): void; onRemoved(): void };
  sleep: { onSleep(): void; onWake(): void };
  runTimer(): void;
  hasTimer(): boolean;
  spawnEnd(kind: "sleep" | "udev", cause: unknown): void;
  stops: number;
}

const makeHarness = (overrides: Partial<RuntimeEnv> = {}): Harness => {
  const logs: LogEntry[] = [];
  let signalHandler = (): void => undefined;
  let pending: (() => void) | null = null;
  const kills = { sleep: 0, udev: 0 };
  const dataListeners: { sleep?: (chunk: string) => void; udev?: (chunk: string) => void } = {};
  const ends: { sleep?: (cause: unknown) => void; udev?: (cause: unknown) => void } = {};

  const child = (which: "sleep" | "udev"): ChildLike => ({
    stdout: {
      setEncoding: vi.fn(),
      on: (_event, listener) => {
        dataListeners[which] = listener;
      },
    },
    on: (event, listener) => {
      if (event === "close") {
        ends[which] = listener;
      }
    },
    kill: () => {
      kills[which]++;
    },
  });

  let spawnCount = 0;
  // The runtime creates the sleep source first, then the udev source.
  const spawn = vi.fn(() => child(spawnCount++ === 0 ? "sleep" : "udev"));

  const env: RuntimeEnv = {
    spawn,
    net: okNet(),
    brightness: 80,
    devicePresentAtStart: false,
    openBackend: async () => makeBackend(),
    registerSignals: (handler) => {
      signalHandler = handler;
    },
    exit: vi.fn(),
    setTimer: (fn) => {
      pending = fn;
      return { id: 1 };
    },
    clearTimer: () => {
      pending = null;
    },
    log: (entry) => logs.push(entry),
    ...overrides,
  };

  const feed = (which: "sleep" | "udev", text: string): void => dataListeners[which]?.(text);

  return {
    env,
    logs,
    signal: () => signalHandler(),
    udev: {
      onAdded: () => feed("udev", "ACTION=add\nID_VENDOR_ID=0fd9\n\n"),
      onRemoved: () => feed("udev", "ACTION=remove\nID_VENDOR_ID=0fd9\n\n"),
    },
    sleep: {
      onSleep: () => feed("sleep", "PrepareForSleep (true)\n"),
      onWake: () => feed("sleep", "PrepareForSleep (false)\n"),
    },
    runTimer: () => {
      const fn = pending;
      pending = null;
      fn?.();
    },
    hasTimer: () => pending !== null,
    spawnEnd: (kind, cause) => ends[kind]?.(cause),
    get stops() {
      return kills.sleep + kills.udev;
    },
  };
};

describe("startRuntime", () => {
  it("rejects with LockHeldError when the lock is already held", async () => {
    const h = makeHarness({ net: busyNet() });
    await expect(startRuntime(h.env)).rejects.toThrow(/already running/);
  });

  it("opens on startup when the device is already present, resetting then repainting", async () => {
    const backend = makeBackend();
    const repaint = vi.fn(async () => undefined);
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend, repaint });
    await startRuntime(h.env);
    await tick();

    expect(backend.write).toHaveBeenCalledOnce(); // key-stream reset
    expect(backend.sendFeatureReport).toHaveBeenCalledOnce(); // brightness
    expect(repaint).toHaveBeenCalledWith(backend);
    expect(h.hasTimer()).toBe(true); // polling started
  });

  it("logs an open failure and stays absent", async () => {
    const h = makeHarness({ openBackend: async () => Promise.reject(new Error("no node")) });
    const runtime = await startRuntime(h.env);
    h.udev.onAdded();
    await tick();

    expect(h.logs.some((l) => l.message.includes("open-failed"))).toBe(true);
    runtime.stop();
  });

  it("polls: delivers input, then idles, and stops the loop on read error", async () => {
    const reads: RawRead[] = [
      { kind: "bytes", data: new Uint8Array(14) },
      { kind: "timeout" },
      { kind: "error", error: new Error("io") },
    ];
    let i = 0;
    const backend = makeBackend({ read: vi.fn(async () => reads[i++]) });
    const onInput = vi.fn();
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend, onInput });
    await startRuntime(h.env);
    await tick();

    h.runTimer();
    await tick();
    expect(onInput).toHaveBeenCalledOnce();

    h.runTimer();
    await tick(); // idle reschedules

    h.runTimer();
    await tick(); // error -> close + notice, no reschedule
    expect(h.logs.some((l) => l.message.includes("read-error"))).toBe(true);
    expect(h.hasTimer()).toBe(false);
    expect(backend.close).toHaveBeenCalled();
  });

  it("closes before suspend and reopens after resume", async () => {
    const first = makeBackend();
    const second = makeBackend();
    let opened = 0;
    const h = makeHarness({
      devicePresentAtStart: true,
      openBackend: async () => (opened++ === 0 ? first : second),
    });
    await startRuntime(h.env);
    await tick();

    h.sleep.onSleep();
    await tick();
    expect(first.close).toHaveBeenCalled();

    h.sleep.onWake();
    await tick();
    expect(second.write).toHaveBeenCalled(); // reset after reopen
    expect(second.sendFeatureReport).toHaveBeenCalled(); // brightness reapplied
  });

  it("logs write failures and recovers from a zombie handle on notifyWriteFailure", async () => {
    const first = makeBackend({
      write: vi.fn(async () => {
        throw new Error("EIO");
      }),
      sendFeatureReport: vi.fn(async () => {
        throw new Error("no feature");
      }),
    });
    const second = makeBackend();
    let opened = 0;
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => (opened++ === 0 ? first : second) });
    const runtime = await startRuntime(h.env);
    await tick();

    expect(h.logs.some((l) => l.message.includes("key-stream reset failed"))).toBe(true);
    expect(h.logs.some((l) => l.message.includes("feature report unavailable: brightness"))).toBe(true);

    runtime.notifyWriteFailure(new Error("dead"));
    await tick();
    expect(first.close).toHaveBeenCalled();
    expect(second.write).toHaveBeenCalled(); // reopened and reset
    expect(h.logs.some((l) => l.message.includes("suspend-zombie"))).toBe(true);
  });

  it("skips a poll that fires after the state left open", async () => {
    const backend = makeBackend();
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend });
    await startRuntime(h.env);
    await tick();

    h.sleep.onSleep(); // state -> suspended synchronously; close effect still queued
    h.runTimer(); // pending poll fires but state is no longer open
    await tick();
    expect(h.env.exit).not.toHaveBeenCalled();
  });

  it("ignores a read that completes after the handle changed", async () => {
    const d = defer<RawRead>();
    const backend = makeBackend({ read: vi.fn(() => d.promise) });
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend });
    await startRuntime(h.env);
    await tick();

    h.runTimer(); // poll begins, awaiting the read
    await tick();
    h.udev.onRemoved(); // closes the handle mid-read
    await tick();
    d.resolve({ kind: "timeout" });
    await tick();
    expect(h.hasTimer()).toBe(false); // did not reschedule against the stale handle
  });

  it("tolerates an input report with no onInput hook", async () => {
    const reads: RawRead[] = [{ kind: "bytes", data: new Uint8Array(14) }];
    let i = 0;
    const backend = makeBackend({ read: vi.fn(async () => reads[i++] ?? { kind: "timeout" }) });
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend });
    await startRuntime(h.env);
    await tick();

    h.runTimer();
    await tick();
    expect(h.hasTimer()).toBe(true); // rescheduled without an onInput hook
  });

  it("leaves the logo up on shutdown and exits", async () => {
    const backend = makeBackend();
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend });
    await startRuntime(h.env);
    await tick();

    h.signal();
    await tick();

    // show-logo is a feature report; two feature reports total (brightness + logo).
    expect((backend.sendFeatureReport as ReturnType<typeof vi.fn>).mock.calls.length).toBe(2);
    expect(backend.close).toHaveBeenCalled();
    expect(h.env.exit).toHaveBeenCalledOnce();
    expect(h.stops).toBe(2); // both sources killed on cleanup
  });

  it("swallows a close error during unplug teardown", async () => {
    const backend = makeBackend({
      close: vi.fn(async () => {
        throw new Error("device already gone");
      }),
    });
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend });
    await startRuntime(h.env);
    await tick();

    h.udev.onRemoved();
    await tick();
    expect(backend.close).toHaveBeenCalled(); // rejection swallowed, no crash
  });

  it("handles unplug then replug", async () => {
    const h = makeHarness({ devicePresentAtStart: false });
    await startRuntime(h.env);

    h.udev.onAdded();
    await tick();
    h.udev.onRemoved();
    await tick();
    h.udev.onAdded();
    await tick();
    expect(h.hasTimer()).toBe(true);
  });

  it("logs when a monitor source ends", async () => {
    const h = makeHarness();
    await startRuntime(h.env);
    h.spawnEnd("sleep", new Error("gone"));
    h.spawnEnd("udev", new Error("gone"));
    expect(h.logs.filter((l) => l.message.includes("ended")).length).toBe(2);
  });
});
