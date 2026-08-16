/**
 * The operating-system port for the voice stack.
 *
 * Everything the audio layer needs from the host is expressed here as two
 * functions. Core modules take this port as an argument and never import
 * `node:child_process` themselves, which is what lets the whole directory move
 * into its own package without rewriting the parts that matter — and what lets
 * the tests run without a microphone.
 */

/** A running capture process, seen as a byte stream with an end. */
export interface SpawnedProcess {
  onData(handler: (chunk: Uint8Array) => void): void;
  /** Fires once when the process ends, whatever the reason. */
  onExit(handler: (code: number | null) => void): void;
  /** Requests termination. Safe to call after exit. */
  kill(): void;
}

export interface SystemPort {
  /** Runs a command to completion and returns its stdout. */
  run(command: string, args: readonly string[]): Promise<string>;
  /** Starts a long-running command whose stdout is consumed incrementally. */
  spawn(command: string, args: readonly string[]): SpawnedProcess;
}
