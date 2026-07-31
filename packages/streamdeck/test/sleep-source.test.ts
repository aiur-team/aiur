import { describe, expect, it, vi } from "vitest";

import type { ChildLike, SpawnLike } from "../src/line-source.js";
import { createSleepSource, parsePrepareForSleep } from "../src/sleep-source.js";

describe("parsePrepareForSleep", () => {
  it("maps the pre-suspend true to sleep and post-resume false to wake", () => {
    expect(parsePrepareForSleep("... PrepareForSleep (true)")).toBe("sleep");
    expect(parsePrepareForSleep("... PrepareForSleep (false)")).toBe("wake");
  });

  it("ignores lines without the signal", () => {
    expect(parsePrepareForSleep("some other dbus line")).toBeNull();
  });

  it("ignores a PrepareForSleep line that carries no boolean", () => {
    expect(parsePrepareForSleep("PrepareForSleep")).toBeNull();
  });
});

const fakeChild = (): { child: ChildLike; emitData: (chunk: string) => void } => {
  const dataListeners: ((chunk: string) => void)[] = [];
  return {
    child: {
      stdout: { setEncoding: vi.fn(), on: (_e, l) => dataListeners.push(l) },
      on: vi.fn(),
      kill: vi.fn(),
    },
    emitData: (chunk) => dataListeners.forEach((l) => l(chunk)),
  };
};

describe("createSleepSource", () => {
  it("dispatches sleep and wake from monitor lines", () => {
    const { child, emitData } = fakeChild();
    const spawn: SpawnLike = vi.fn(() => child);
    const onSleep = vi.fn();
    const onWake = vi.fn();
    createSleepSource(spawn, { onSleep, onWake });

    emitData("PrepareForSleep (true)\nunrelated\nPrepareForSleep (false)\n");

    expect(onSleep).toHaveBeenCalledOnce();
    expect(onWake).toHaveBeenCalledOnce();
  });
});
