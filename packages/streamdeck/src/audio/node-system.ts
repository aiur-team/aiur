/**
 * The Node implementation of the audio stack's operating-system port.
 *
 * This is deliberately the only file under `src/audio/` that imports a Node
 * built-in, and it contains no decisions — just the translation from
 * `child_process` to the two-function `SystemPort`. Keeping it separate is
 * what lets the rest of the stack be tested without spawning anything, and
 * what lets a different host swap the port wholesale.
 */

import { spawn as nodeSpawn } from "node:child_process";
import type { SpawnedProcess, SystemPort } from "./system.js";

/** Guards against a runaway enumeration hanging the sidecar's startup. */
export const RUN_TIMEOUT_MS = 5_000;

export interface NodeSystemOptions {
  /**
   * How long `run` waits before killing the child. Defaults to
   * `RUN_TIMEOUT_MS`; a test overrides it so the timeout path can be exercised
   * against a command that would otherwise outlive the suite.
   */
  readonly runTimeoutMs?: number;
}

export function createNodeSystem(options: NodeSystemOptions = {}): SystemPort {
  const runTimeoutMs = options.runTimeoutMs ?? RUN_TIMEOUT_MS;

  return {
    run(command: string, args: readonly string[]): Promise<string> {
      return new Promise<string>((resolve, reject) => {
        const child = nodeSpawn(command, [...args], { stdio: ["ignore", "pipe", "ignore"] });
        const chunks: Buffer[] = [];
        const timer = setTimeout(() => {
          child.kill("SIGKILL");
          reject(new Error(`${command} timed out`));
        }, runTimeoutMs);
        // Node's timer always has `unref`; the enumeration must never be the
        // reason the sidecar's event loop stays alive.
        timer.unref();

        child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
        child.on("error", (error) => {
          clearTimeout(timer);
          reject(error);
        });
        child.on("close", (code) => {
          clearTimeout(timer);
          if (code === 0) {
            resolve(Buffer.concat(chunks).toString("utf8"));
            return;
          }
          reject(new Error(`${command} exited ${String(code)}`));
        });
      });
    },

    spawn(command: string, args: readonly string[]): SpawnedProcess {
      // stderr is discarded rather than piped: the recorder is chatty about
      // stream state, and an unread pipe eventually blocks the child.
      const child = nodeSpawn(command, [...args], { stdio: ["ignore", "pipe", "ignore"] });

      return {
        onData(handler: (chunk: Uint8Array) => void): void {
          child.stdout.on("data", (chunk: Buffer) => handler(new Uint8Array(chunk)));
        },
        onExit(handler: (code: number | null) => void): void {
          // `error` fires when the binary is missing, so both are routed to the
          // same handler; otherwise a machine without `parecord` installed
          // would hold the mic key open forever. Node emits `error` *and then*
          // `close` in that case, so the first event wins: `SpawnedProcess`
          // promises the handler fires once, and a consumer that reported both
          // would print a spurious second failure over the real reason.
          let finished = false;
          const settle = (code: number | null): void => {
            if (finished) return;
            finished = true;
            handler(code);
          };
          child.on("error", () => settle(null));
          child.on("close", (code) => settle(code));
        },
        kill(): void {
          // SIGINT, not SIGTERM. `parec` discards its buffer on SIGTERM, which
          // loses the tail of a short utterance; SIGINT makes it flush first.
          child.kill("SIGINT");
        },
      };
    },
  };
}
