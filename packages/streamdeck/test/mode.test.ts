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

  it("clamps a negative newestChatIndex to 0 when entering logs", () => {
    expect(
      transitionMode(commandState(), { type: "command.press", command: "logs", bounds: { newestChatIndex: -5 } }).state.chatIndex,
    ).toBe(0);
  });

  it("registers a live-refresh timer in logs mode", () => {
    const timer = { id: "live-refresh" };
    const logsState = transitionMode(commandState(), { type: "command.press", command: "logs" }).state;

    expect(transitionMode(logsState, { type: "live-refresh.started", timer }).state.liveRefreshTimer).toBe(timer);
  });

  it("returns from logs to commands and exposes the timer cleanup effect", () => {
    const timer = { id: "live-refresh" };
    const logsState = transitionMode(commandState(), { type: "command.press", command: "logs" }).state;
    const state = transitionMode(logsState, { type: "live-refresh.started", timer }).state;

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

  // The order is a parity contract with the Elixir emulator's command row, so
  // it is asserted as a whole rather than key by key.
  it("renders pause, logs, mic, settings and commands, with the pause label toggled", () => {
    expect(commandKeys({ paused: true })).toEqual([
      { command: "pause", label: "Play" },
      { command: "logs", label: "Logs" },
      { command: "mic", label: "Mic" },
      { command: "settings", label: "Settings" },
      { command: "commands", label: "Commands" },
      null,
      null,
      null,
    ]);
    expect(commandKeys({ paused: false })[0]).toEqual({ command: "pause", label: "Pause" });
  });

  // Nothing to send before the operator has spoken: a lit Send key would invite
  // a press that delivers an empty message.
  it("adds Send and Cancel only while the buffer holds text", () => {
    expect(commandKeys({ paused: false }, true).slice(4)).toEqual([
      { command: "commands", label: "Commands" },
      { command: "send", label: "Send" },
      { command: "cancel", label: "Cancel" },
      null,
    ]);
  });

  it("opens settings from commands and returns to commands, not to the grid", () => {
    const settings = transitionMode(commandState(), { type: "command.press", command: "settings" }).state;
    expect(settings).toMatchObject({ mode: "settings", activeAgentId: "agent-1" });
    expect(transitionMode(settings, { type: "back" }).state).toMatchObject({ mode: "cmd", activeAgentId: "agent-1" });
  });

  it("ignores a settings press from anywhere but commands", () => {
    const state = createModeState();
    expect(transitionMode(state, { type: "command.press", command: "settings" })).toEqual({ state, effects: [] });
  });

  it("holds and releases TestMic on the settings surface", () => {
    const settings = transitionMode(commandState(), { type: "command.press", command: "settings" }).state;
    const held = transitionMode(settings, { type: "mic.down" }).state;
    expect(held.micHeld).toBe(true);
    expect(transitionMode(held, { type: "mic.up" }).state.micHeld).toBe(false);
  });

  it("ignores a mic hold in a mode with no mic key", () => {
    const state = createModeState();
    expect(transitionMode(state, { type: "mic.down" })).toEqual({ state, effects: [] });
    expect(transitionMode(state, { type: "mic.up" })).toEqual({ state, effects: [] });
  });

  it.each(["mic.up", "mic.leave", "mic.cancel"] as const)("releases mic on %s", (type) => {
    const held = transitionMode(commandState(), { type: "mic.down" }).state;

    expect(transitionMode(held, { type }).state.micHeld).toBe(false);
  });

  it("holds mic only while the command key is down", () => {
    expect(transitionMode(commandState(), { type: "mic.down" }).state.micHeld).toBe(true);
  });

  it("opens the Commands page from commands and returns to commands, not to the grid", () => {
    const commands = transitionMode(commandState(), { type: "command.press", command: "commands" }).state;
    expect(commands).toMatchObject({ mode: "commands", activeAgentId: "agent-1" });
    expect(transitionMode(commands, { type: "back" }).state).toMatchObject({ mode: "cmd", activeAgentId: "agent-1" });
  });

  it("ignores a commands press from anywhere but commands mode", () => {
    const state = createModeState();
    expect(transitionMode(state, { type: "command.press", command: "commands" })).toEqual({ state, effects: [] });
  });

  it("drops the mic hold when entering and leaving the Commands page", () => {
    const held = transitionMode(commandState(), { type: "mic.down" }).state;
    const commands = transitionMode(held, { type: "command.press", command: "commands" }).state;
    expect(commands).toMatchObject({ mode: "commands", micHeld: false });
    expect(transitionMode(commands, { type: "back" }).state).toMatchObject({ mode: "cmd", micHeld: false });
  });
});
