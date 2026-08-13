/**
 * Generic "spawn a long-running monitor and read its stdout line by line"
 * helper, shared by the logind sleep source and the udev hotplug source.
 *
 * Neither logind's `PrepareForSleep` signal nor udev hotplug has a dependency-
 * free Node binding, and native addons (`node-hid`, `udev`) drag `libudev` /
 * `libusb` build steps into CI. Instead we tail the line output of the standard
 * CLIs (`busctl`/`gdbus`, `udevadm monitor`) that ship with systemd and parse
 * their lines. The `spawn` primitive is injected so this is testable with a
 * fake child process and never spawns anything under test.
 */

/** Minimal readable-stream surface we consume from a child's stdout. */
export interface ReadableLike {
  setEncoding(encoding: "utf8"): void;
  on(event: "data", listener: (chunk: string) => void): void;
}

/** Minimal child-process surface {@link spawnLineSource} needs. */
export interface ChildLike {
  stdout: ReadableLike | null;
  on(event: "error" | "close", listener: (arg?: unknown) => void): void;
  kill(): void;
}

/** Injected spawn primitive (`node:child_process` spawn in the real process). */
export type SpawnLike = (command: string, args: readonly string[]) => ChildLike;

/** A running line source; {@link stop} kills the child. */
export interface LineSubscription {
  stop(): void;
}

export interface LineSourceHandlers {
  onLine(line: string): void;
  /** Called if the child cannot be spawned or exits; recovery is the caller's. */
  onEnd?(cause: unknown): void;
}

/**
 * Spawns `command args`, splits stdout into complete lines (buffering any
 * trailing partial line across chunks), and delivers each line to `onLine`. A
 * spawn error or child exit calls `onEnd`.
 */
export const spawnLineSource = (
  spawn: SpawnLike,
  command: string,
  args: readonly string[],
  handlers: LineSourceHandlers,
): LineSubscription => {
  const child = spawn(command, args);
  let buffer = "";

  if (child.stdout) {
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      buffer += chunk;
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        handlers.onLine(buffer.slice(0, newline));
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
      }
    });
  }

  child.on("error", (cause) => handlers.onEnd?.(cause));
  child.on("close", (cause) => handlers.onEnd?.(cause));

  return { stop: () => child.kill() };
};
