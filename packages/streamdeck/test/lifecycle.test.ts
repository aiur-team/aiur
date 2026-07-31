import { describe, expect, it } from "vitest";

import {
  createLifecycleState,
  transitionLifecycle,
  type LifecycleEffect,
  type LifecycleEvent,
  type LifecycleState,
  type LinkState,
} from "../src/lifecycle.js";

const from = (link: LinkState): LifecycleState => ({ link });

const run = (link: LinkState, event: LifecycleEvent): { link: LinkState; effects: readonly LifecycleEffect[] } => {
  const { state, effects } = transitionLifecycle(from(link), event);
  return { link: state.link, effects };
};

const types = (effects: readonly LifecycleEffect[]): string[] => effects.map((effect) => effect.type);

describe("createLifecycleState", () => {
  it("starts absent", () => {
    expect(createLifecycleState()).toEqual({ link: "absent" });
  });
});

describe("absent", () => {
  it("opens on a device add", () => {
    expect(run("absent", { type: "device-added" })).toEqual({ link: "opening", effects: [{ type: "open-device" }] });
  });

  it("stops on shutdown", () => {
    expect(run("absent", { type: "shutdown" })).toEqual({ link: "stopped", effects: [{ type: "stop" }] });
  });

  it("ignores an unrelated event", () => {
    expect(run("absent", { type: "wake" })).toEqual({ link: "absent", effects: [] });
  });
});

describe("opening", () => {
  it("resets, applies brightness, and repaints once open", () => {
    const result = run("opening", { type: "device-opened" });
    expect(result.link).toBe("open");
    expect(types(result.effects)).toEqual(["send-key-stream-reset", "apply-brightness", "repaint"]);
  });

  it("falls back to absent with a notice when the open fails", () => {
    const result = run("opening", { type: "open-failed", error: new Error("nope") });
    expect(result.link).toBe("absent");
    expect(result.effects).toEqual([{ type: "notice", code: "open-failed", cause: expect.any(Error) }]);
  });

  it("closes when the device is removed mid-open", () => {
    expect(run("opening", { type: "device-removed" })).toEqual({ link: "absent", effects: [{ type: "close-device" }] });
  });

  it("suspends by closing", () => {
    expect(run("opening", { type: "sleep" })).toEqual({ link: "suspended", effects: [{ type: "close-device" }] });
  });

  it("shuts down by closing and stopping", () => {
    expect(types(run("opening", { type: "shutdown" }).effects)).toEqual(["close-device", "stop"]);
  });

  it("ignores an unrelated event", () => {
    expect(run("opening", { type: "wake" })).toEqual({ link: "opening", effects: [] });
  });
});

describe("open", () => {
  it("closes on unplug", () => {
    expect(run("open", { type: "device-removed" })).toEqual({ link: "absent", effects: [{ type: "close-device" }] });
  });

  it("recovers from a genuine read error", () => {
    const result = run("open", { type: "read-error", error: new Error("io") });
    expect(result.link).toBe("absent");
    expect(types(result.effects)).toEqual(["close-device", "notice"]);
  });

  it("reopens on the suspend-zombie write heartbeat failure", () => {
    const result = run("open", { type: "write-failed", error: new Error("EIO") });
    expect(result.link).toBe("opening");
    expect(types(result.effects)).toEqual(["close-device", "notice", "open-device"]);
  });

  it("suspends by closing", () => {
    expect(run("open", { type: "sleep" })).toEqual({ link: "suspended", effects: [{ type: "close-device" }] });
  });

  it("leaves the logo up on shutdown", () => {
    expect(types(run("open", { type: "shutdown" }).effects)).toEqual(["show-logo", "close-device", "stop"]);
  });

  it("ignores a duplicate device add", () => {
    expect(run("open", { type: "device-added" })).toEqual({ link: "open", effects: [] });
  });
});

describe("suspended", () => {
  it("reopens on wake", () => {
    expect(run("suspended", { type: "wake" })).toEqual({ link: "opening", effects: [{ type: "open-device" }] });
  });

  it("closes if unplugged while asleep", () => {
    expect(run("suspended", { type: "device-removed" })).toEqual({
      link: "absent",
      effects: [{ type: "close-device" }],
    });
  });

  it("shuts down cleanly", () => {
    expect(types(run("suspended", { type: "shutdown" }).effects)).toEqual(["close-device", "stop"]);
  });

  it("ignores a redundant sleep", () => {
    expect(run("suspended", { type: "sleep" })).toEqual({ link: "suspended", effects: [] });
  });
});

describe("stopped", () => {
  it("is terminal", () => {
    expect(run("stopped", { type: "wake" })).toEqual({ link: "stopped", effects: [] });
  });
});
