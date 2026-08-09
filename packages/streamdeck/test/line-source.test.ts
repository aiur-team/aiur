import { describe, expect, it, vi } from "vitest";

import { spawnLineSource, type ChildLike, type SpawnLike } from "../src/line-source.js";

interface FakeChild extends ChildLike {
  emitData(chunk: string): void;
  emit(event: "error" | "close", arg?: unknown): void;
}

const fakeChild = (withStdout = true): FakeChild => {
  const dataListeners: ((chunk: string) => void)[] = [];
  const listeners = new Map<string, (arg?: unknown) => void>();
  return {
    stdout: withStdout
      ? {
          setEncoding: vi.fn(),
          on: (_event, listener) => dataListeners.push(listener),
        }
      : null,
    on: (event, listener) => listeners.set(event, listener),
    kill: vi.fn(),
    emitData: (chunk) => dataListeners.forEach((l) => l(chunk)),
    emit: (event, arg) => listeners.get(event)?.(arg),
  };
};

const spawnReturning = (child: ChildLike): SpawnLike => vi.fn(() => child);

describe("spawnLineSource", () => {
  it("splits complete lines and buffers a partial trailing line", () => {
    const child = fakeChild();
    const onLine = vi.fn();
    spawnLineSource(spawnReturning(child), "cmd", ["a"], { onLine });

    child.emitData("one\ntw");
    child.emitData("o\nthree\n");

    expect(onLine.mock.calls.map((c) => c[0])).toEqual(["one", "two", "three"]);
  });

  it("reports child error and close through onEnd", () => {
    const child = fakeChild();
    const onEnd = vi.fn();
    spawnLineSource(spawnReturning(child), "cmd", [], { onLine: vi.fn(), onEnd });

    child.emit("error", new Error("spawn failed"));
    child.emit("close", 1);
    expect(onEnd).toHaveBeenCalledTimes(2);
  });

  it("tolerates a missing onEnd handler and no stdout", () => {
    const child = fakeChild(false);
    spawnLineSource(spawnReturning(child), "cmd", [], { onLine: vi.fn() });
    expect(() => child.emit("error")).not.toThrow();
    expect(() => child.emit("close")).not.toThrow();
  });

  it("kills the child on stop", () => {
    const child = fakeChild();
    const sub = spawnLineSource(spawnReturning(child), "cmd", [], { onLine: vi.fn() });
    sub.stop();
    expect(child.kill).toHaveBeenCalledOnce();
  });
});
