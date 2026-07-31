import { describe, expect, it, vi } from "vitest";

import {
  acquireLock,
  createAbstractSocketBinding,
  DEFAULT_LOCK_NAME,
  LockHeldError,
  type LockBinding,
  type NetLike,
  type NetServerLike,
} from "../src/lock.js";

describe("acquireLock", () => {
  it("acquires via the injected binding using the abstract address", async () => {
    const handle = { release: vi.fn() };
    const binding: LockBinding = { listen: vi.fn(async () => handle) };

    await expect(acquireLock(DEFAULT_LOCK_NAME, binding)).resolves.toBe(handle);
    expect(binding.listen).toHaveBeenCalledWith(`\0${DEFAULT_LOCK_NAME}`);
  });

  it("maps EADDRINUSE to an actionable LockHeldError", async () => {
    const binding: LockBinding = {
      listen: async () => {
        throw Object.assign(new Error("in use"), { code: "EADDRINUSE" });
      },
    };

    await expect(acquireLock("x", binding)).rejects.toBeInstanceOf(LockHeldError);
    await expect(acquireLock("x", binding)).rejects.toThrow(/already running/);
  });

  it("re-throws any other binding failure unchanged", async () => {
    const failure = new Error("permission denied");
    const binding: LockBinding = {
      listen: async () => {
        throw failure;
      },
    };

    await expect(acquireLock("x", binding)).rejects.toBe(failure);
  });
});

/** A fake net server that fires either `listening` or `error` on listen. */
const fakeNet = (outcome: "listening" | { code: string }): { net: NetLike; server: NetServerLike; close: () => void } => {
  const listeners = new Map<string, (arg?: unknown) => void>();
  const close = vi.fn();
  const server: NetServerLike = {
    once: (event, listener) => listeners.set(event, listener),
    removeListener: (event) => listeners.delete(event),
    listen: () => {
      if (outcome === "listening") {
        listeners.get("listening")?.();
      } else {
        listeners.get("error")?.(Object.assign(new Error("in use"), outcome));
      }
    },
    close,
  };
  return { net: { createServer: () => server }, server, close };
};

describe("createAbstractSocketBinding", () => {
  it("resolves a handle whose release closes the server", async () => {
    const { net, close } = fakeNet("listening");
    const handle = await createAbstractSocketBinding(net).listen("\0name");
    handle.release();
    expect(close).toHaveBeenCalledOnce();
  });

  it("rejects with the emitted error when the bind fails", async () => {
    const { net } = fakeNet({ code: "EADDRINUSE" });
    await expect(createAbstractSocketBinding(net).listen("\0name")).rejects.toMatchObject({ code: "EADDRINUSE" });
  });
});
