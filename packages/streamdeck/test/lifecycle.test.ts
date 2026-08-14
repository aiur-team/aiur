import { describe, expect, it } from "vitest";

import {
  createLifecycleState,
  reconnectDelayMs,
  RECONNECT_ALERT_AFTER,
  RECONNECT_BASE_MS,
  RECONNECT_CAP_MS,
  transitionLifecycle,
  type LifecycleEffect,
  type LifecycleEvent,
  type LifecycleState,
  type LinkState,
} from "../src/lifecycle.js";

const from = (link: LinkState, attempt = 0): LifecycleState => ({ link, attempt });

const run = (
  state: LinkState | LifecycleState,
  event: LifecycleEvent,
): { link: LinkState; attempt: number; effects: readonly LifecycleEffect[] } => {
  const initial = typeof state === "string" ? from(state) : state;
  const { state: next, effects } = transitionLifecycle(initial, event);
  return { link: next.link, attempt: next.attempt, effects };
};

const types = (effects: readonly LifecycleEffect[]): string[] => effects.map((effect) => effect.type);

describe("createLifecycleState", () => {
  it("starts absent with no failures", () => {
    expect(createLifecycleState()).toEqual({ link: "absent", attempt: 0 });
  });
});

describe("reconnectDelayMs", () => {
  it("starts at the base delay and doubles", () => {
    expect(reconnectDelayMs(0)).toBe(RECONNECT_BASE_MS);
    expect(reconnectDelayMs(1)).toBe(RECONNECT_BASE_MS * 2);
    expect(reconnectDelayMs(2)).toBe(RECONNECT_BASE_MS * 4);
  });

  it("caps at the ceiling", () => {
    expect(reconnectDelayMs(100)).toBe(RECONNECT_CAP_MS);
  });
});

describe("absent", () => {
  it("opens on a device add", () => {
    expect(run("absent", { type: "device-added" })).toEqual({
      link: "opening",
      attempt: 0,
      effects: [{ type: "open-device" }],
    });
  });

  it("stops on shutdown", () => {
    expect(run("absent", { type: "shutdown" })).toEqual({ link: "stopped", attempt: 0, effects: [{ type: "stop" }] });
  });

  it("ignores an unrelated event", () => {
    expect(run("absent", { type: "wake" })).toEqual({ link: "absent", attempt: 0, effects: [] });
  });
});

describe("opening", () => {
  it("resets, applies brightness, and repaints once open", () => {
    const result = run("opening", { type: "device-opened" });
    expect(result.link).toBe("open");
    expect(result.attempt).toBe(0);
    expect(types(result.effects)).toEqual(["send-key-stream-reset", "apply-brightness", "repaint"]);
  });

  // Opening proves nothing on its own: a wedged deck accepts opens and fails
  // every write. Clearing the count here made that cycle reconnect forever at
  // the base delay instead of backing off.
  it("keeps the failure count across a successful open", () => {
    const result = run(from("opening", 4), { type: "device-opened" });
    expect(result.attempt).toBe(4);
  });

  it("clears the failure count only once a repaint has landed", () => {
    const opened = run(from("opening", 4), { type: "device-opened" });
    expect(run(opened, { type: "link-healthy" }).attempt).toBe(0);
  });

  it("backs off further each time writes keep failing on an open link", () => {
    const first = run(from("open", 0), { type: "write-failed", error: new Error("zombie") });
    const reopened = run({ ...first, link: "opening" } as typeof first, { type: "device-opened" });
    const second = run(reopened, { type: "write-failed", error: new Error("zombie") });
    expect(second.attempt).toBeGreaterThan(first.attempt);
  });

  it("reconnects with backoff on the first open failure", () => {
    const result = run("opening", { type: "open-failed", error: new Error("nope") });
    expect(result.link).toBe("reconnecting");
    expect(result.attempt).toBe(1);
    expect(result.effects).toEqual([
      { type: "notice", code: "open-failed", cause: expect.any(Error) },
      { type: "schedule-reopen", delayMs: RECONNECT_BASE_MS },
    ]);
  });

  it("grows the backoff on repeated open failures", () => {
    const result = run(from("opening", 3), { type: "open-failed", error: new Error("nope") });
    expect(result.attempt).toBe(4);
    expect(result.effects).toContainEqual({ type: "schedule-reopen", delayMs: reconnectDelayMs(3) });
  });

  it("raises an operator alert once retries reach the threshold", () => {
    const result = run(from("opening", RECONNECT_ALERT_AFTER - 1), { type: "open-failed", error: new Error("nope") });
    expect(result.attempt).toBe(RECONNECT_ALERT_AFTER);
    expect(types(result.effects)).toEqual(["notice", "schedule-reopen", "alert"]);
  });

  it("closes when the device is removed mid-open", () => {
    expect(run("opening", { type: "device-removed" })).toEqual({
      link: "absent",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("suspends by closing", () => {
    expect(run("opening", { type: "sleep" })).toEqual({
      link: "suspended",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("shuts down by closing and stopping", () => {
    expect(types(run("opening", { type: "shutdown" }).effects)).toEqual(["close-device", "stop"]);
  });

  it("ignores an unrelated event", () => {
    expect(run("opening", { type: "wake" })).toEqual({ link: "opening", attempt: 0, effects: [] });
  });
});

describe("open", () => {
  it("closes on unplug", () => {
    expect(run("open", { type: "device-removed" })).toEqual({
      link: "absent",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("recovers from a genuine read error with backoff instead of going dead", () => {
    const result = run("open", { type: "read-error", error: new Error("io") });
    expect(result.link).toBe("reconnecting");
    expect(result.attempt).toBe(1);
    expect(types(result.effects)).toEqual(["close-device", "notice", "schedule-reopen"]);
  });

  it("recovers from the suspend-zombie write failure with backoff", () => {
    const result = run("open", { type: "write-failed", error: new Error("EIO") });
    expect(result.link).toBe("reconnecting");
    expect(result.attempt).toBe(1);
    // No bare open-device: the scheduled reopen carries the backoff, so
    // opens-succeed/writes-fail cannot cycle at the write cadence.
    expect(types(result.effects)).toEqual(["close-device", "notice", "schedule-reopen"]);
    expect(result.effects[1]).toMatchObject({ type: "notice", code: "suspend-zombie" });
  });

  it("leaves the logo up before suspending", () => {
    expect(types(run("open", { type: "sleep" }).effects)).toEqual(["show-logo", "close-device"]);
  });

  it("leaves the logo up on shutdown", () => {
    expect(types(run("open", { type: "shutdown" }).effects)).toEqual(["show-logo", "close-device", "stop"]);
  });

  it("ignores a duplicate device add", () => {
    expect(run("open", { type: "device-added" })).toEqual({ link: "open", attempt: 0, effects: [] });
  });
});

describe("reconnecting", () => {
  it("opens again when the backoff elapses, preserving the failure count", () => {
    const result = run(from("reconnecting", 2), { type: "reopen" });
    expect(result).toEqual({ link: "opening", attempt: 2, effects: [{ type: "open-device" }] });
  });

  it("opens immediately and resets backoff on a fresh udev add", () => {
    const result = run(from("reconnecting", 3), { type: "device-added" });
    expect(result).toEqual({ link: "opening", attempt: 0, effects: [{ type: "open-device" }] });
  });

  it("goes absent when the device is removed", () => {
    expect(run(from("reconnecting", 2), { type: "device-removed" })).toEqual({
      link: "absent",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("suspends by closing", () => {
    expect(run(from("reconnecting", 2), { type: "sleep" })).toEqual({
      link: "suspended",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("shuts down cleanly", () => {
    expect(types(run(from("reconnecting", 2), { type: "shutdown" }).effects)).toEqual(["close-device", "stop"]);
  });

  it("ignores an unrelated event", () => {
    expect(run(from("reconnecting", 2), { type: "wake" })).toEqual({
      link: "reconnecting",
      attempt: 2,
      effects: [],
    });
  });
});

describe("suspended", () => {
  it("reopens on wake", () => {
    expect(run("suspended", { type: "wake" })).toEqual({
      link: "opening",
      attempt: 0,
      effects: [{ type: "open-device" }],
    });
  });

  it("closes if unplugged while asleep", () => {
    expect(run("suspended", { type: "device-removed" })).toEqual({
      link: "absent",
      attempt: 0,
      effects: [{ type: "close-device" }],
    });
  });

  it("shuts down cleanly", () => {
    expect(types(run("suspended", { type: "shutdown" }).effects)).toEqual(["close-device", "stop"]);
  });

  it("ignores a redundant sleep", () => {
    expect(run("suspended", { type: "sleep" })).toEqual({ link: "suspended", attempt: 0, effects: [] });
  });
});

describe("stopped", () => {
  it("is terminal", () => {
    expect(run("stopped", { type: "wake" })).toEqual({ link: "stopped", attempt: 0, effects: [] });
  });
});
