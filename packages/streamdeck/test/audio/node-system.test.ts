import { describe, expect, it } from "vitest";
import { RUN_TIMEOUT_MS, createNodeSystem } from "../../src/audio/node-system.js";

const MISSING_BINARY = "definitely-not-a-real-binary-xyz";

/**
 * Yields the event loop repeatedly so every queued child-process event is
 * delivered. This counts turns rather than milliseconds, so it does not race a
 * clock: Node emits `close` one turn after `error`, and twenty turns is an
 * enormous margin on that.
 */
const drainEvents = async (): Promise<void> => {
  for (let turn = 0; turn < 20; turn += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
};

/** Resolves once the spawned process has ended, with the code it reported. */
const exitCode = (process: ReturnType<ReturnType<typeof createNodeSystem>["spawn"]>): Promise<number | null> =>
  new Promise((resolve) => {
    process.onExit(resolve);
  });

describe("node run", () => {
  it("returns the command's stdout", async () => {
    await expect(createNodeSystem().run("echo", ["hi"])).resolves.toBe("hi\n");
  });

  it("rejects on a non-zero exit rather than returning partial output", async () => {
    await expect(createNodeSystem().run("false", [])).rejects.toThrow("false exited 1");
  });

  it("rejects when the binary is not installed", async () => {
    // `error` fires instead of `close` here, which is a different code path
    // from a command that ran and failed.
    await expect(createNodeSystem().run(MISSING_BINARY, [])).rejects.toThrow(/ENOENT/);
  });

  it("kills a command that never returns, so startup cannot hang", async () => {
    // The margin is deliberately enormous — a 20 ms budget against a 30 s
    // command — so no amount of scheduling jitter can make this flake.
    const system = createNodeSystem({ runTimeoutMs: 20 });
    await expect(system.run("sleep", ["30"])).rejects.toThrow("sleep timed out");
  });

  it("defaults to a timeout generous enough for real enumeration", async () => {
    expect(RUN_TIMEOUT_MS).toBe(5_000);
    // The default must not be so tight that a working `echo` trips it.
    await expect(createNodeSystem().run("echo", ["ok"])).resolves.toBe("ok\n");
  });
});

describe("node spawn", () => {
  it("streams stdout and reports the exit code", async () => {
    const process = createNodeSystem().spawn("echo", ["chunk"]);
    const chunks: Uint8Array[] = [];
    process.onData((chunk) => chunks.push(chunk));
    const code = await exitCode(process);

    expect(code).toBe(0);
    expect(Buffer.concat(chunks).toString("utf8")).toBe("chunk\n");
    expect(chunks[0]).toBeInstanceOf(Uint8Array);
  });

  it("terminates a long-running recorder on kill", async () => {
    const process = createNodeSystem().spawn("sleep", ["30"]);
    const ended = exitCode(process);
    process.kill();

    // A signalled process leaves no exit code, which is what the caller sees.
    await expect(ended).resolves.toBeNull();
  });

  it("interrupts rather than terminates, so parec flushes its buffer", async () => {
    // `parec` discards its buffer on SIGTERM and loses the tail of a short
    // utterance; only SIGINT makes it flush. This stand-in ignores SIGTERM and
    // exits 7 on SIGINT, so the assertion below can only pass on SIGINT — a
    // SIGTERM would leave it running and the awaited exit would never arrive.
    const process = createNodeSystem().spawn("sh", [
      "-c",
      'trap "" TERM; trap "exit 7" INT; echo ready; while :; do sleep 0.05; done',
    ]);
    const ended = exitCode(process);
    // The stand-in announces itself once its traps are installed, so the signal
    // is sent at a known point rather than after a guessed delay.
    await new Promise<void>((resolve) => {
      process.onData(() => resolve());
    });
    process.kill();

    await expect(ended).resolves.toBe(7);
  });

  it("ends the capture when the recorder is not installed", async () => {
    const process = createNodeSystem().spawn(MISSING_BINARY, []);
    // Otherwise a machine without `parecord` would hold the mic key open.
    await expect(exitCode(process)).resolves.toBeNull();
  });

  it("reports the end of a missing recorder exactly once", async () => {
    // Node emits `error` and then `close` for a missing binary; `SpawnedProcess`
    // promises the handler fires once, so the spurious second report — which
    // would print over the real reason — must be suppressed.
    const process = createNodeSystem().spawn(MISSING_BINARY, []);
    const codes: (number | null)[] = [];
    process.onExit((code) => codes.push(code));

    await drainEvents();

    expect(codes).toEqual([null]);
  });

  it("tolerates a kill after the process already ended", async () => {
    const process = createNodeSystem().spawn("echo", ["done"]);
    await exitCode(process);
    expect(() => process.kill()).not.toThrow();
  });
});
