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
  timerCount(): number;
  spawnCalls(): number;
  spawnEnd(kind: "sleep" | "udev", cause: unknown): void;
  stops: number;
}

const makeHarness = (overrides: Partial<RuntimeEnv> = {}): Harness => {
  const logs: LogEntry[] = [];
  let signalHandler = (): void => undefined;
  // FIFO of scheduled timers (poll, reconnect backoff, monitor restart). Each
  // runTimer() dequeues and fires the oldest, matching one-shot setTimeout.
  const timers = new Map<number, () => void>();
  let nextTimerId = 1;
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
    onBackendClosed: vi.fn(),
    openBackend: async () => makeBackend(),
    registerSignals: (handler) => {
      signalHandler = handler;
    },
    exit: vi.fn(),
    setTimer: (fn) => {
      const id = nextTimerId++;
      timers.set(id, fn);
      return id;
    },
    clearTimer: (handle) => {
      timers.delete(handle as number);
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
      const next = timers.entries().next();
      if (next.done) {
        return;
      }
      const [id, fn] = next.value;
      timers.delete(id);
      fn();
    },
    hasTimer: () => timers.size > 0,
    timerCount: () => timers.size,
    spawnCalls: () => spawn.mock.calls.length,
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

  it("reconnects with backoff after an open failure instead of going dead", async () => {
    let opened = 0;
    const backend = makeBackend();
    const h = makeHarness({
      openBackend: async () => {
        if (opened++ === 0) {
          throw new Error("no node");
        }
        return backend;
      },
    });
    const runtime = await startRuntime(h.env);
    h.udev.onAdded();
    await tick();

    // Logged loudly at error, and a reopen is scheduled — not permanently absent.
    const notice = h.logs.find((l) => l.message.includes("open-failed"));
    expect(notice?.level).toBe("error");
    expect(h.hasTimer()).toBe(true);

    // When the backoff elapses, it opens successfully and starts polling.
    h.runTimer();
    await tick();
    expect(backend.write).toHaveBeenCalled(); // key-stream reset on the reopen
    expect(h.hasTimer()).toBe(true); // polling now scheduled
    runtime.stop();
  });

  it("raises an operator alert once open retries reach the cap", async () => {
    const h = makeHarness({ openBackend: async () => Promise.reject(new Error("no node")) });
    const runtime = await startRuntime(h.env);
    h.udev.onAdded();
    await tick();

    // First failure already happened; drive the remaining retries via the backoff timer.
    for (let i = 1; i < 5; i++) {
      h.runTimer();
      await tick();
    }
    expect(h.logs.some((l) => l.level === "error" && l.message.includes("present but not opening"))).toBe(true);
    runtime.stop();
  });

  it("polls: delivers input, then idles, and recovers with backoff on a read error", async () => {
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
    await tick(); // error -> close + notice(error) + schedule-reopen
    const notice = h.logs.find((l) => l.message.includes("read-error"));
    expect(notice?.level).toBe("error");
    expect(backend.close).toHaveBeenCalled();
    // The device is still plugged in: a reopen is scheduled rather than left dead.
    expect(h.hasTimer()).toBe(true);
  });

  it("closes before suspend and reopens after resume", async () => {
    const first = makeBackend();
    const second = makeBackend();
    let opened = 0;
    const onBackendClosed = vi.fn();
    const h = makeHarness({
      devicePresentAtStart: true,
      onBackendClosed,
      openBackend: async () => (opened++ === 0 ? first : second),
    });
    await startRuntime(h.env);
    await tick();

    h.sleep.onSleep();
    await tick();
    expect(first.close).toHaveBeenCalled();
    expect(onBackendClosed).toHaveBeenCalledWith(first);

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
    expect(h.logs.some((l) => l.message.includes("suspend-zombie"))).toBe(true);

    // Recovery is via the bounded backoff, not an immediate reopen, so a
    // writes-fail-forever handle cannot cycle at the write cadence.
    h.runTimer();
    await tick();
    expect(second.write).toHaveBeenCalled(); // reopened and reset
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

  it("keeps the effect chain alive when an effect throws", async () => {
    const backend = makeBackend();
    const repaint = vi.fn(async () => {
      throw new Error("render boom");
    });
    const h = makeHarness({ devicePresentAtStart: true, openBackend: async () => backend, repaint });
    await startRuntime(h.env);
    await tick();
    expect(h.logs.some((l) => l.message.includes("effect failed: repaint"))).toBe(true);

    // A later event's effects still run despite the earlier rejection.
    h.signal();
    await tick();
    expect(h.env.exit).toHaveBeenCalledOnce();
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

  it("restarts a monitor source at error level when it ends, then respawns", async () => {
    const h = makeHarness();
    await startRuntime(h.env);
    const spawnsAtStart = h.spawnCalls(); // 2: sleep + udev

    h.spawnEnd("sleep", new Error("gone"));
    h.spawnEnd("udev", new Error("gone"));
    const ends = h.logs.filter((l) => l.message.includes("ended; restarting"));
    expect(ends.length).toBe(2);
    expect(ends.every((l) => l.level === "error")).toBe(true);

    // Each end scheduled a restart; firing the backoff respawns the monitor.
    h.runTimer();
    h.runTimer();
    expect(h.spawnCalls()).toBe(spawnsAtStart + 2);
  });

  it("cancels a pending monitor restart on stop", async () => {
    const h = makeHarness();
    const runtime = await startRuntime(h.env);
    h.spawnEnd("sleep", new Error("gone")); // schedules a restart timer
    expect(h.hasTimer()).toBe(true);

    runtime.stop();
    expect(h.hasTimer()).toBe(false); // restart timer cleared by cleanup
  });

  it("does not restart a monitor that ends after the runtime stops", async () => {
    const h = makeHarness();
    const runtime = await startRuntime(h.env);
    runtime.stop();
    const spawnsAfterStop = h.spawnCalls();

    h.spawnEnd("sleep", new Error("gone"));
    expect(h.logs.some((l) => l.message.includes("ended; restarting"))).toBe(false);
    expect(h.hasTimer()).toBe(false);
    expect(h.spawnCalls()).toBe(spawnsAfterStop);
  });
});
