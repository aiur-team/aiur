/**
 * The Node implementation of the audio stack's playback port.
 *
 * This is the output mirror of `node-system.ts`: the only file in the stack
 * that knows a playback binary, and it contains no decisions. Raw PCM from
 * ElevenLabs' `pcm_*` output formats is piped straight into `pacat`
 * (PulseAudio's raw playback tool — the sibling of the `parec` the capture
 * side uses), so no decoder is needed on the host. A different host supplies
 * its own `PlaybackPort` and the core is unchanged.
 */

import { spawn as nodeSpawn } from "node:child_process";
import type { PlaybackPort } from "./playback.js";

export const PACAT = "pacat";
/** s16le, 44.1 kHz mono — the shape ElevenLabs `pcm_44100` output is. */
export const DEFAULT_PCM_ARGS = ["--raw", "--format=s16le", "--rate=44100", "--channels=1"] as const;

/** The minimal spawned-process surface the port needs, injected for tests. */
export interface SpawnedPlaybackProcess {
  readonly stdin: {
    write(chunk: Uint8Array): boolean;
    end(): void;
    once(event: "drain", handler: () => void): void;
    on(event: "error", handler: () => void): void;
  };
  /**
   * Registers the process-end handler. Fires exactly once, whether the
   * process exited cleanly or failed to spawn.
   */
  onExit(handler: (code: number | null) => void): void;
}

export type PlaybackSpawn = (binary: string, args: readonly string[]) => SpawnedPlaybackProcess;

export interface PacatPlaybackOptions {
  /** Binary to run; injectable so tests exercise the plumbing without audio. */
  readonly binary?: string;
  /** Extra args appended after the PCM format args. */
  readonly args?: readonly string[];
  /** Injected spawn; defaults to `node:child_process`. */
  readonly spawn?: PlaybackSpawn;
}

const defaultSpawn: PlaybackSpawn = (binary, args) => {
  // stderr is discarded rather than piped, matching the capture side: the
  // playback tool is chatty, and an unread pipe eventually blocks the child.
  const child = nodeSpawn(binary, [...args], { stdio: ["pipe", "ignore", "ignore"] });
  return {
    stdin: {
      write: (chunk) => child.stdin.write(chunk),
      end: () => child.stdin.end(),
      once: (event, handler) => {
        child.stdin.once(event, handler);
      },
      on: (event, handler) => {
        child.stdin.on(event, handler);
      },
    },
    onExit(handler: (code: number | null) => void): void {
      // `error` fires when the binary is missing, so both are routed to the
      // same handler; otherwise a machine without `pacat` installed would
      // hold the port open forever. Node emits `error` *and then* `close` in
      // that case, so the first event wins — the caller must see one exit.
      let finished = false;
      const settle = (code: number | null): void => {
        if (finished) return;
        finished = true;
        handler(code);
      };
      child.on("error", () => settle(null));
      child.on("close", (code) => settle(code));
    },
  };
};

export function createPacatPlayback(options: PacatPlaybackOptions = {}): PlaybackPort {
  const binary = options.binary ?? PACAT;
  const args = [...DEFAULT_PCM_ARGS, ...(options.args ?? [])];
  const spawn = options.spawn ?? defaultSpawn;
  const child = spawn(binary, args);

  let closed = false;
  let exited = false;
  const exitPromise = new Promise<number | null>((resolve) => {
    child.onExit((code) => {
      exited = true;
      resolve(code);
    });
  });
  // A write that lands after the sink has gone (EPIPE) must not crash the
  // sidecar; the exit path above is what reports the failure. Marking the
  // port dead here also stops the next write from queueing into a dead pipe.
  child.stdin.on("error", () => {
    exited = true;
  });

  return {
    write(chunk: Uint8Array): Promise<void> | void {
      if (closed || exited) {
        return undefined;
      }
      if (!child.stdin.write(chunk)) {
        return new Promise<void>((resolve) => {
          child.stdin.once("drain", resolve);
        });
      }
      return undefined;
    },
    async close(): Promise<void> {
      if (closed) {
        return;
      }
      closed = true;
      child.stdin.end();
      await exitPromise;
    },
  };
}
