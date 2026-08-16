import { describe, expect, it, vi } from "vitest";
import {
  CAPTURE_LATENCY_MS,
  FIRST_BYTE_TIMEOUT_MS,
  PAREC,
  captureArgs,
  startCapture,
  type Scheduler,
} from "../../src/audio/capture.js";
import { DEFAULT_PCM_FORMAT } from "../../src/audio/pcm.js";
import type { SpawnedProcess, SystemPort } from "../../src/audio/system.js";

interface SpawnHarness {
  readonly system: SystemPort;
  readonly commands: { command: string; args: readonly string[] }[];
  readonly killed: () => number;
  /** Delivers one stdout chunk to whatever `startCapture` registered. */
  emit(chunk: Uint8Array): void;
  /** Ends the recorder process with the given exit code. */
  exit(code: number | null): void;
}

const spawnHarness = (): SpawnHarness => {
  const commands: { command: string; args: readonly string[] }[] = [];
  let onData: ((chunk: Uint8Array) => void) | null = null;
  let onExit: ((code: number | null) => void) | null = null;
  let kills = 0;

  const process: SpawnedProcess = {
    onData: (handler) => {
      onData = handler;
    },
    onExit: (handler) => {
      onExit = handler;
    },
    kill: () => {
      kills += 1;
    },
  };

  return {
    system: {
      run: () => Promise.reject(new Error("startCapture must not run a command")),
      spawn: (command, args) => {
        commands.push({ command, args });
        return process;
      },
    },
    commands,
    killed: () => kills,
    emit: (chunk) => onData?.(chunk),
    exit: (code) => onExit?.(code),
  };
};

interface SchedulerHarness {
  readonly scheduler: Scheduler;
  readonly delay: () => number | null;
  readonly cancels: () => number;
  /** Runs the deadline callback by hand; no real timer is ever armed. */
  fire(): void;
}

const schedulerHarness = (): SchedulerHarness => {
  let callback: (() => void) | null = null;
  let delay: number | null = null;
  let cancels = 0;
  return {
    scheduler: (given, delayMs) => {
      callback = given;
      delay = delayMs;
      return {
        cancel: () => {
          cancels += 1;
        },
      };
    },
    delay: () => delay,
    cancels: () => cancels,
    fire: () => callback?.(),
  };
};

describe("recorder arguments", () => {
  it("asks for 16 kHz mono s16le at the latency parec needs to start cleanly", () => {
    // 20 ms is mandatory: without it parec emits nothing for about a second and
    // then starts mid-word, eating the first word of every push-to-talk.
    expect(CAPTURE_LATENCY_MS).toBe(20);
    expect(captureArgs(null, DEFAULT_PCM_FORMAT, CAPTURE_LATENCY_MS)).toEqual([
      "--raw",
      "--format=s16le",
      "--rate=16000",
      "--channels=1",
      "--latency-msec=20",
    ]);
  });

  it("pins the source when a device was chosen", () => {
    expect(captureArgs("alsa_input.yeti", DEFAULT_PCM_FORMAT, CAPTURE_LATENCY_MS)).toContain(
      "--device=alsa_input.yeti",
    );
  });

  it("honours a custom format and latency", () => {
    expect(captureArgs(null, { sampleRate: 48_000, channels: 2, bitDepth: 16 }, 100)).toEqual([
      "--raw",
      "--format=s16le",
      "--rate=48000",
      "--channels=2",
      "--latency-msec=100",
    ]);
  });
});

describe("chunked capture", () => {
  it("spawns parec with the resolved argv", () => {
    const harness = spawnHarness();
    startCapture(
      { system: harness.system, deviceId: "alsa_input.yeti", scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError: vi.fn() },
    );
    expect(harness.commands).toEqual([
      {
        command: PAREC,
        args: ["--raw", "--format=s16le", "--rate=16000", "--channels=1", "--latency-msec=20", "--device=alsa_input.yeti"],
      },
    ]);
  });

  it("passes a custom format and latency through to the recorder", () => {
    const harness = spawnHarness();
    startCapture(
      {
        system: harness.system,
        deviceId: null,
        format: { sampleRate: 8_000, channels: 1, bitDepth: 16 },
        latencyMs: 250,
        scheduler: schedulerHarness().scheduler,
      },
      { onChunk: vi.fn(), onError: vi.fn() },
    );
    expect(harness.commands[0]?.args).toEqual([
      "--raw",
      "--format=s16le",
      "--rate=8000",
      "--channels=1",
      "--latency-msec=250",
    ]);
  });

  it("forwards stdout chunks as they arrive", () => {
    const harness = spawnHarness();
    const onChunk = vi.fn();
    startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk, onError: vi.fn() },
    );

    harness.emit(new Uint8Array([1, 2]));
    harness.emit(new Uint8Array([3, 4]));

    expect(onChunk).toHaveBeenNthCalledWith(1, new Uint8Array([1, 2]));
    expect(onChunk).toHaveBeenNthCalledWith(2, new Uint8Array([3, 4]));
  });

  it("drops chunks that arrive after the operator let go of the key", () => {
    const harness = spawnHarness();
    const onChunk = vi.fn();
    const capture = startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk, onError: vi.fn() },
    );

    capture.stop();
    // The pipe still holds buffered audio when the process is killed; that
    // audio belongs to a hold the operator already ended.
    harness.emit(new Uint8Array([1, 2]));

    expect(onChunk).not.toHaveBeenCalled();
  });

  it("kills the recorder once however often stop is called", () => {
    const harness = spawnHarness();
    const capture = startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError: vi.fn() },
    );

    capture.stop();
    capture.stop();

    expect(harness.killed()).toBe(1);
  });

  it("does not report a failure for the exit a requested stop caused", () => {
    const harness = spawnHarness();
    const onError = vi.fn();
    const capture = startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError },
    );

    capture.stop();
    harness.exit(143);

    expect(onError).not.toHaveBeenCalled();
  });

  it("distinguishes a clean unexpected end from a recorder failure", () => {
    const clean = spawnHarness();
    const onCleanError = vi.fn();
    startCapture(
      { system: clean.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError: onCleanError },
    );
    clean.exit(0);
    expect(onCleanError).toHaveBeenCalledWith("Microphone capture ended unexpectedly");

    const broken = spawnHarness();
    const onBrokenError = vi.fn();
    startCapture(
      { system: broken.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError: onBrokenError },
    );
    broken.exit(1);
    expect(onBrokenError).toHaveBeenCalledWith("Microphone capture failed (exit 1)");
  });

  it("reports a missing recorder, which exits with no code at all", () => {
    const harness = spawnHarness();
    const onError = vi.fn();
    startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError },
    );
    harness.exit(null);
    expect(onError).toHaveBeenCalledWith("Microphone capture failed (exit null)");
  });

  it("stops silently after an unexpected exit already ended the capture", () => {
    const harness = spawnHarness();
    const capture = startCapture(
      { system: harness.system, deviceId: null, scheduler: schedulerHarness().scheduler },
      { onChunk: vi.fn(), onError: vi.fn() },
    );

    harness.exit(1);
    capture.stop();

    // The process is already gone; killing it again would be a second signal
    // to a pid that may have been reused.
    expect(harness.killed()).toBe(0);
  });

  it("arms the deadline with the real timer when no scheduler is injected", () => {
    const harness = spawnHarness();
    const capture = startCapture({ system: harness.system, deviceId: null }, { onChunk: vi.fn(), onError: vi.fn() });

    // The default timer is unref'd, so an armed deadline cannot hold the suite
    // (or the sidecar) open; stopping immediately clears it either way.
    expect(harness.commands).toHaveLength(1);
    capture.stop();
    expect(harness.killed()).toBe(1);
  });
});

describe("first-byte deadline", () => {
  it("arms the deadline at the documented budget", () => {
    expect(FIRST_BYTE_TIMEOUT_MS).toBe(750);
    const scheduler = schedulerHarness();
    startCapture(
      { system: spawnHarness().system, deviceId: null, scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError: vi.fn() },
    );
    expect(scheduler.delay()).toBe(750);
  });

  it("honours a custom deadline", () => {
    const scheduler = schedulerHarness();
    startCapture(
      { system: spawnHarness().system, deviceId: null, scheduler: scheduler.scheduler, firstByteTimeoutMs: 40 },
      { onChunk: vi.fn(), onError: vi.fn() },
    );
    expect(scheduler.delay()).toBe(40);
  });

  it("turns a silent recorder into an error rather than a hung key", () => {
    const harness = spawnHarness();
    const scheduler = schedulerHarness();
    const onError = vi.fn();
    startCapture(
      { system: harness.system, deviceId: "alsa_input.gone", scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError },
    );

    // A recorder handed a device that no longer exists writes nothing at all,
    // not even to stderr, and would otherwise hold the mic key open forever.
    scheduler.fire();

    expect(onError).toHaveBeenCalledWith("Microphone produced no audio - check the selected device");
    expect(harness.killed()).toBe(1);
  });

  it("reports a silent recorder once, and not again on the exit that follows", () => {
    const harness = spawnHarness();
    const scheduler = schedulerHarness();
    const onError = vi.fn();
    startCapture(
      { system: harness.system, deviceId: null, scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError },
    );

    scheduler.fire();
    harness.exit(null);

    expect(onError).toHaveBeenCalledOnce();
  });

  it("cancels the deadline on the first chunk", () => {
    const harness = spawnHarness();
    const scheduler = schedulerHarness();
    const onError = vi.fn();
    startCapture(
      { system: harness.system, deviceId: null, scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError },
    );

    harness.emit(new Uint8Array([1, 2]));

    expect(scheduler.cancels()).toBe(1);
    // Even a scheduler that fires a cancelled callback anyway must not report
    // silence once audio has been heard.
    scheduler.fire();
    expect(onError).not.toHaveBeenCalled();
  });

  it("cancels the deadline when the operator releases the key", () => {
    const harness = spawnHarness();
    const scheduler = schedulerHarness();
    const onError = vi.fn();
    const capture = startCapture(
      { system: harness.system, deviceId: null, scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError },
    );

    capture.stop();

    expect(scheduler.cancels()).toBe(1);
    // A hold shorter than the deadline is normal, not a broken microphone.
    scheduler.fire();
    expect(onError).not.toHaveBeenCalled();
    expect(harness.killed()).toBe(1);
  });

  it("cancels the deadline when the recorder exits first", () => {
    const harness = spawnHarness();
    const scheduler = schedulerHarness();
    const onError = vi.fn();
    startCapture(
      { system: harness.system, deviceId: null, scheduler: scheduler.scheduler },
      { onChunk: vi.fn(), onError },
    );

    harness.exit(1);

    expect(scheduler.cancels()).toBe(1);
    scheduler.fire();
    // The real reason is the exit code, not a generic silence message.
    expect(onError).toHaveBeenCalledOnce();
    expect(onError).toHaveBeenCalledWith("Microphone capture failed (exit 1)");
  });
});
