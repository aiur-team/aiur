import { describe, expect, it } from "vitest";
import {
  DEFAULT_PCM_ARGS,
  PACAT,
  createPacatPlayback,
  type PlaybackSpawn,
  type SpawnedPlaybackProcess,
} from "../../src/audio/node-playback.js";

const MISSING_BINARY = "definitely-not-a-real-binary-xyz";

interface FakeProcess extends SpawnedPlaybackProcess {
  readonly writes: Uint8Array[];
  endCalls: number;
  writeResult: boolean;
  drainHandler: (() => void) | null;
  errorHandler: (() => void) | null;
  exitHandler: ((code: number | null) => void) | null;
}

interface FakeSpawn {
  readonly spawn: PlaybackSpawn;
  readonly calls: Array<{ binary: string; args: readonly string[] }>;
  readonly processes: FakeProcess[];
}

function makeFakeSpawn(): FakeSpawn {
  const calls: FakeSpawn["calls"] = [];
  const processes: FakeProcess[] = [];

  const spawn: PlaybackSpawn = (binary, args) => {
    calls.push({ binary, args });
    const process: FakeProcess = {
      writes: [],
      endCalls: 0,
      writeResult: true,
      drainHandler: null,
      errorHandler: null,
      exitHandler: null,
      stdin: {
        write(chunk) {
          process.writes.push(chunk);
          return process.writeResult;
        },
        end() {
          process.endCalls += 1;
        },
        once(event, handler) {
          if (event === "drain") {
            process.drainHandler = handler;
          }
        },
        on(event, handler) {
          if (event === "error") {
            process.errorHandler = handler;
          }
        },
      },
      onExit(handler) {
        process.exitHandler = handler;
      },
    };
    processes.push(process);
    return process;
  };

  return { spawn, calls, processes };
}

const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

describe("createPacatPlayback", () => {
  it("spawns pacat with the raw-PCM args by default", () => {
    const fake = makeFakeSpawn();
    createPacatPlayback({ spawn: fake.spawn });
    expect(fake.calls).toEqual([{ binary: PACAT, args: [...DEFAULT_PCM_ARGS] }]);
  });

  it("honours a custom binary and extra args", () => {
    const fake = makeFakeSpawn();
    createPacatPlayback({ binary: "cat", args: ["--rate=22050"], spawn: fake.spawn });
    expect(fake.calls[0].binary).toBe("cat");
    expect(fake.calls[0].args).toEqual([...DEFAULT_PCM_ARGS, "--rate=22050"]);
  });

  it("writes chunks to the child and releases it once on close", async () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });
    const chunk = new Uint8Array([1, 2, 3]);

    expect(port.write(chunk)).toBeUndefined();
    expect(fake.processes[0].writes).toEqual([chunk]);

    const closed = port.close();
    expect(fake.processes[0].endCalls).toBe(1);
    fake.processes[0].exitHandler?.(0);
    await closed;
  });

  it("ignores writes after close", async () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });

    const closed = port.close();
    fake.processes[0].exitHandler?.(0);
    await closed;

    expect(port.write(new Uint8Array([9]))).toBeUndefined();
    expect(fake.processes[0].writes).toEqual([]);
  });

  it("closing twice is a no-op", async () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });

    const first = port.close();
    fake.processes[0].exitHandler?.(0);
    await first;

    await port.close();
    expect(fake.processes[0].endCalls).toBe(1);
  });

  it("ignores writes once the process has exited", async () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });

    fake.processes[0].exitHandler?.(0);

    expect(port.write(new Uint8Array([7]))).toBeUndefined();
    expect(fake.processes[0].writes).toEqual([]);
  });

  it("stops accepting writes after a stdin error (a dead sink)", () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });

    fake.processes[0].errorHandler?.();

    expect(port.write(new Uint8Array([8]))).toBeUndefined();
    expect(fake.processes[0].writes).toEqual([]);
  });

  it("resolves a write only after the child drains when backpressure hits", async () => {
    const fake = makeFakeSpawn();
    const port = createPacatPlayback({ spawn: fake.spawn });
    fake.processes[0].writeResult = false;

    let resolved = false;
    const pending = port.write(new Uint8Array([5]));
    expect(pending).not.toBeUndefined();
    pending?.then(() => {
      resolved = true;
    });

    await tick();
    expect(resolved).toBe(false);

    fake.processes[0].drainHandler?.();
    await tick();
    expect(resolved).toBe(true);
  });

  it("drives a real child process when no spawn is injected", async () => {
    // `cat` consumes stdin and exits 0 on EOF, so the real child-process
    // plumbing is exercised without an audio device. The write is far larger
    // than the child's stdin high-water mark, so `write` returns false and
    // the real drain listener is registered — the path the fake cannot hit.
    const port = createPacatPlayback({ binary: "cat" });

    port.write(new Uint8Array(1024 * 1024));
    await port.close();
  });

  it("settles a missing binary without throwing or hanging", async () => {
    // `error` then `close` both fire for a missing binary; the onExit guard
    // lets the first settle and the port's stdin error handler absorbs the
    // resulting EPIPE rather than crashing the process.
    const port = createPacatPlayback({ binary: MISSING_BINARY });

    await port.close();
  });
});
