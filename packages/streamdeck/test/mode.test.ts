import { describe, expect, it } from "vitest";

import { commandKeys, createModeState, transitionMode } from "../src/mode.js";

describe("Stream Deck mode state", () => {
  const commandState = () => transitionMode(createModeState(), { type: "agent.press", agentId: "agent-1" }).state;

  it("opens commands for the pressed grid agent", () => {
    expect(commandState()).toMatchObject({ mode: "cmd", activeAgentId: "agent-1" });
  });

  it("opens logs and resets its navigation state", () => {
    const state = {
      ...commandState(),
      eventIndex: 4,
      eventSelection: 3,
      chatIndex: 1,
      dial0Rotation: 45,
      dial3Rotation: 80,
    };

    expect(transitionMode(state, { type: "command.press", command: "logs", bounds: { newestChatIndex: 8 } }).state).toMatchObject({
      mode: "logs",
      eventIndex: 0,
      eventSelection: 0,
      chatIndex: 8,
      dial0Rotation: 0,
      dial3Rotation: 0,
    });
  });

  it("opens logs with chatIndex 0 when no bounds are provided", () => {
    expect(transitionMode(commandState(), { type: "command.press", command: "logs" }).state).toMatchObject({
      mode: "logs",
      chatIndex: 0,
    });
  });

  it("returns from logs to commands and exposes the timer cleanup effect", () => {
    const timer = { id: "live-refresh" };
    const state = { ...commandState(), mode: "logs" as const, liveRefreshTimer: timer };

    expect(transitionMode(state, { type: "back" })).toEqual({
      state: { ...state, mode: "cmd", liveRefreshTimer: null, micHeld: false },
      effects: [{ type: "clear-live-refresh", timer }],
    });
  });

  it("returns from logs to commands with no effects when no timer is set", () => {
    const state = { ...commandState(), mode: "logs" as const, liveRefreshTimer: null };

    expect(transitionMode(state, { type: "back" }).effects).toEqual([]);
  });

  it("returns from commands to grid and clears the active agent", () => {
    expect(transitionMode(commandState(), { type: "back" }).state).toMatchObject({ mode: "grid", activeAgentId: null });
  });

  it("does nothing when backing out of the grid", () => {
    const state = createModeState();

    expect(transitionMode(state, { type: "back" })).toEqual({ state, effects: [] });
  });

  it("renders exactly four commands and the expected toggled labels", () => {
    expect(commandKeys({ paused: true, prioritized: true })).toEqual([
      { command: "pause", label: "Play" },
      { command: "priority", label: "Deprioritize" },
      { command: "logs", label: "Logs" },
      { command: "mic", label: "Mic" },
      null,
      null,
      null,
      null,
    ]);
    expect(commandKeys({ paused: false, prioritized: false }).slice(0, 2)).toEqual([
      { command: "pause", label: "Pause" },
      { command: "priority", label: "Prioritize" },
    ]);
  });

  it.each(["mic.up", "mic.leave", "mic.cancel"] as const)("releases mic on %s", (type) => {
    const held = transitionMode(commandState(), { type: "mic.down" }).state;

    expect(transitionMode(held, { type }).state.micHeld).toBe(false);
  });

  it("holds mic only while the command key is down", () => {
    expect(transitionMode(commandState(), { type: "mic.down" }).state.micHeld).toBe(true);
  });
});
