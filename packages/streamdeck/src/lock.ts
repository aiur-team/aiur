/**
 * Advisory single-instance lock.
 *
 * `hidraw` has no exclusive-access mechanism — there is no `EVIOCGRAB`
 * equivalent, so two processes can both `open()` the same `/dev/hidrawN` and
 * interleave writes, which corrupts multi-chunk image transfers rather than
 * failing cleanly. The kernel will not help; we take our own lock and refuse to
 * start when another instance holds it.
 *
 * We bind an **abstract** unix socket (a name in the abstract namespace, i.e.
 * a leading NUL byte). The abstract namespace has no filesystem entry, so it
 * needs no cleanup path and cannot leave a stale pidfile behind after a crash —
 * the kernel drops the name the instant the holding socket closes. A second
 * bind of the same name fails with `EADDRINUSE`, which is exactly the
 * "someone else holds it" signal we want.
 *
 * The `net`-level binding is injected so the acquisition policy here is pure
 * and testable; {@link createAbstractSocketBinding} wraps `node:net` for the
 * real process.
 */

/** Default abstract-socket name for the sidecar's single-instance lock. */
export const DEFAULT_LOCK_NAME = "streamdeck-sidecar";

/** A held lock; releasing it frees the name for another instance. */
export interface LockHandle {
  release(): void;
}

/**
 * Binds a named abstract socket, resolving with a handle or rejecting with an
 * `EADDRINUSE`-coded error when the name is already held.
 */
export interface LockBinding {
  listen(address: string): Promise<LockHandle>;
}

/** Thrown when another instance already holds the lock. */
export class LockHeldError extends Error {
  constructor(name: string) {
    super(
      `Another Stream Deck sidecar is already running (advisory lock "${name}" is held). ` +
        `Stop the other instance — check "systemctl --user status aiur-streamdeck" and "fuser /dev/hidraw*" — then start exactly one.`,
    );
    this.name = "LockHeldError";
  }
}

/**
 * Acquires the advisory lock. Resolves with the handle on success; rejects with
 * a {@link LockHeldError} carrying an actionable message when the name is
 * already held, and re-throws any other binding failure unchanged.
 */
export const acquireLock = async (name: string, binding: LockBinding): Promise<LockHandle> => {
  try {
    return await binding.listen(abstractAddress(name));
  } catch (error) {
    if (isAddressInUse(error)) {
      throw new LockHeldError(name);
    }
    throw error;
  }
};

/** Abstract-namespace address for a lock name: a leading NUL, then the name. */
const abstractAddress = (name: string): string => `\0${name}`;

const isAddressInUse = (error: unknown): boolean =>
  typeof error === "object" && error !== null && (error as { code?: unknown }).code === "EADDRINUSE";

/** The minimal `node:net` surface {@link createAbstractSocketBinding} needs. */
export interface NetServerLike {
  listen(address: string): void;
  close(): void;
  once(event: "listening" | "error", listener: (arg?: unknown) => void): void;
  removeListener(event: "listening" | "error", listener: (arg?: unknown) => void): void;
}

export interface NetLike {
  createServer(): NetServerLike;
}

/**
 * Wraps `node:net` as a {@link LockBinding}. The server is left listening on the
 * abstract name for the process lifetime; {@link LockHandle.release} closes it.
 */
export const createAbstractSocketBinding = (net: NetLike): LockBinding => ({
  listen: (address) =>
    new Promise<LockHandle>((resolve, reject) => {
      const server = net.createServer();

      const onListening = (): void => {
        server.removeListener("error", onError);
        resolve({ release: () => server.close() });
      };

      const onError = (error?: unknown): void => {
        server.removeListener("listening", onListening);
        reject(error);
      };

      server.once("listening", onListening);
      server.once("error", onError);
      server.listen(address);
    }),
});
