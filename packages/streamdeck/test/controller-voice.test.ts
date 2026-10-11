import { describe, expect, it, vi } from "vitest";
import { createPhysicalController, type ControllerVoice } from "../src/controller.js";
import { commandIdempotencyKey } from "../src/commands.js";
import type { StreamDeckCommand, StreamDeckCommandsPage, StreamDeckGrid } from "../src/channel.js";
import type { AudioDevice } from "../src/audio/index.js";
import { dialButton, dialButtons, keyReport, keysReport } from "./support/deckReports.js";

const grid = (count = 10): StreamDeckGrid => ({
  agents: Array.from({ length: count }, (_, index) => ({
    identifier: `agent-${index}`,
    bucket: index === 6 ? "running" : "queued",
    title: `Agent ${index}`,
    vendor: "codex",
    progress_percent: 20,
  })),
  total: count,
  windows: Math.ceil(count / 8),
  max_column_offset: Math.max(0, Math.ceil(count / 2) - 4),
});

/**
 * The voice half of the command surface, driven entirely through real HID
 * reports: key 2 is the mic, key 3 opens settings, keys 4 and 5 are Send and
 * Cancel, and on the settings surface key 2 is TestMic — the same slot as the
 * command surface's mic — keys 0, 1, 3, 4, 5 and 6 are the microphones, and 7
 * pages.
 */
describe("voice keys", () => {
  const fakeVoice = (over: Partial<ControllerVoice> = {}) => {
    let text = "";
    let selected: string | null = null;
    let devices: AudioDevice[] = [{ id: "a", label: "Mic A" }, { id: "b", label: "Mic B" }];
    const port: ControllerVoice & { say(value: string): void; setDevices(list: AudioDevice[]): void } = {
      hold: vi.fn(),
      release: vi.fn(),
      message: () => text,
      hasMessage: () => text !== "",
      clear: vi.fn(() => { text = ""; }),
      dispose: vi.fn(),
      microphones: () => devices,
      refresh: vi.fn(),
      selectedDeviceId: () => selected,
      select: vi.fn((id: string) => { selected = id; }),
      say: (value: string) => { text = value; },
      setDevices: (list: AudioDevice[]) => { devices = list; },
      ...over,
    };
    return port;
  };

  /** A controller focused on an agent, with the fake voice port wired in. */
  const focused = (voice: ReturnType<typeof fakeVoice>, say = vi.fn()) => {
    const controller = createPhysicalController({
      grid,
      channel: () => ({ focus: vi.fn(), control: vi.fn(), say, commandsPage: vi.fn(), answerCommand: vi.fn() }),
      voice: () => voice,
      stateChanged: vi.fn(),
    });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    expect(controller.state().mode).toBe("cmd");
    return { controller, say };
  };

  it("starts capture on key 2 down and ends it on key 2 up", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(2, true));
    expect(voice.hold).toHaveBeenCalledOnce();
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keyReport(2, false));
    expect(voice.release).toHaveBeenCalledOnce();
    expect(controller.state().micHeld).toBe(false);
  });

  it("shows Send and Cancel only once the buffer holds settled text", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(2, true));
    expect(controller.state().hasTranscript).toBe(false);
    voice.say("run the tests again");
    controller.handleReport(keyReport(2, false));
    expect(controller.state().hasTranscript).toBe(true);
  });

  it("delivers the buffer through say and clears it, staying in cmd", () => {
    const voice = fakeVoice();
    const { controller, say } = focused(voice);
    voice.say("run the tests again");
    controller.refreshVoice();
    controller.handleReport(keyReport(5, true));
    expect(say).toHaveBeenCalledWith("agent-0", "run the tests again");
    expect(voice.clear).toHaveBeenCalledOnce();
    expect(controller.state()).toMatchObject({ mode: "cmd", hasTranscript: false });
  });

  // The key face and the report that pressed it are a frame apart, so a press
  // that raced the buffer emptying must not deliver a blank turn to the agent.
  it("sends nothing when the buffer emptied under the press", () => {
    const voice = fakeVoice();
    const { controller, say } = focused(voice);
    // CMD_SEND is key 5; pressing it with an empty buffer must not deliver a
    // blank turn to the agent.
    controller.handleReport(keyReport(5, true));
    expect(say).not.toHaveBeenCalled();
  });

  it("clears the buffer without sending on Cancel", () => {
    const voice = fakeVoice();
    const { controller, say } = focused(voice);
    voice.say("forget this");
    controller.refreshVoice();
    controller.handleReport(keyReport(6, true));
    expect(say).not.toHaveBeenCalled();
    expect(voice.clear).toHaveBeenCalledOnce();
    expect(controller.state()).toMatchObject({ mode: "cmd", hasTranscript: false });
  });

  it("opens settings from key 3 and re-enumerates microphones", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(3, true));
    expect(controller.state()).toMatchObject({ mode: "settings", micOffset: 0 });
    expect(voice.refresh).toHaveBeenCalledOnce();
  });

  it("returns from settings to the focused agent's commands with dial A", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    controller.handleReport(dialButton(0));
    expect(controller.state()).toMatchObject({ mode: "cmd", focusedIdentifier: "agent-0" });
  });

  const inSettings = (voice: ReturnType<typeof fakeVoice>) => {
    const { controller } = focused(voice);
    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    expect(controller.state().mode).toBe("settings");
    return controller;
  };

  it("persists the microphone the pressed key names", () => {
    const voice = fakeVoice();
    const controller = inSettings(voice);
    controller.handleReport(keyReport(1, true));
    expect(voice.select).toHaveBeenCalledWith("b");
    // Read back out of the store, not assumed from the press.
    expect(controller.state().selectedMicId).toBe("b");
  });

  it("ignores a press on a microphone key with no device on it", () => {
    const voice = fakeVoice();
    const controller = inSettings(voice);
    controller.handleReport(keyReport(5, true));
    expect(voice.select).not.toHaveBeenCalled();
  });

  it("holds TestMic on key 2 and releases it on key 2 up", () => {
    const voice = fakeVoice();
    const controller = inSettings(voice);
    controller.handleReport(keyReport(2, true));
    expect(voice.hold).toHaveBeenCalledOnce();
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keyReport(2, false));
    expect(voice.release).toHaveBeenCalledOnce();
    expect(controller.state().micHeld).toBe(false);
  });

  /**
   * The move is only real if both halves moved together: key 2 must capture and
   * key 6 — TestMic's old home — must now select the sixth microphone.
   */
  it("captures on key 2 and selects the sixth microphone on key 6", () => {
    const voice = fakeVoice();
    voice.setDevices(Array.from({ length: 6 }, (_, index) => ({ id: `m${index}`, label: `Mic ${index}` })));
    const controller = inSettings(voice);

    controller.handleReport(keyReport(2, true));
    expect(voice.hold).toHaveBeenCalledOnce();
    expect(voice.select).not.toHaveBeenCalled();
    controller.handleReport(keyReport(2, false));

    controller.handleReport(keyReport(6, true));
    expect(voice.select).toHaveBeenCalledWith("m5");
    expect(controller.state()).toMatchObject({ selectedMicId: "m5", micHeld: false });
    expect(voice.hold).toHaveBeenCalledOnce();
  });

  it("pages the microphone list with key 7, wrapping past the last page", () => {
    const voice = fakeVoice();
    voice.setDevices(Array.from({ length: 15 }, (_, index) => ({ id: `m${index}`, label: `Mic ${index}` })));
    const controller = inSettings(voice);
    for (const expected of [6, 12, 0]) {
      controller.handleReport(keyReport(7, true));
      controller.handleReport(keyReport(7, false));
      expect(controller.state().micOffset).toBe(expected);
    }
  });

  it("leaves the page alone when everything fits on one", () => {
    const voice = fakeVoice();
    const controller = inSettings(voice);
    controller.handleReport(keyReport(7, true));
    expect(controller.state().micOffset).toBe(0);
  });

  it("ignores knob 3 on the settings surface", () => {
    const voice = fakeVoice();
    const controller = inSettings(voice);
    controller.handleReport(dialButton(3));
    expect(controller.state().mode).toBe("settings");
  });

  it("stops capture and drops the buffer when the focus is left", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    voice.say("half a thought");
    controller.refreshVoice();
    controller.handleReport(dialButton(0));
    expect(controller.state()).toMatchObject({ mode: "grid", hasTranscript: false });
    expect(voice.dispose).toHaveBeenCalled();
    // A message about one ticket must not follow the operator to the next.
    expect(voice.clear).toHaveBeenCalled();
  });

  it("stops capture and drops the buffer on the demo chord", () => {
    const voice = fakeVoice();
    const controller = createPhysicalController({
      grid,
      channel: () => null,
      voice: () => voice,
      stateChanged: vi.fn(),
      toggleDemo: vi.fn(),
    });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(2, true));
    controller.handleReport(dialButtons([1, 2]));
    expect(controller.state()).toMatchObject({ mode: "grid", micHeld: false });
    expect(voice.dispose).toHaveBeenCalled();
    expect(voice.clear).toHaveBeenCalled();
  });

  // A dropped device must not leave `parec` recording.
  it("stops capture when the backend goes away mid-hold", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(2, true));
    controller.cancel();
    expect(voice.dispose).toHaveBeenCalled();
    expect(controller.state().micHeld).toBe(false);
  });

  it("stops capture when Logs is opened from under a held mic", () => {
    const voice = fakeVoice();
    const { controller } = focused(voice);
    controller.handleReport(keyReport(2, true));
    controller.handleReport(keysReport([1, 2], true));
    expect(controller.state().mode).toBe("logs");
    expect(voice.dispose).toHaveBeenCalled();
  });

  // Every one of these paths has to tolerate a host with no audio at all.
  it("is inert on a host with no voice port", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(keyReport(2, true));
    expect(controller.state().micHeld).toBe(true);
    controller.handleReport(keyReport(2, false));
    controller.handleReport(keyReport(5, true));
    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    expect(controller.state().mode).toBe("settings");
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(7, true));
    controller.refreshVoice();
    expect(controller.state()).toMatchObject({ mode: "settings", micOffset: 0, selectedMicId: null });
  });
});

describe("Commands answer path", () => {
  // The command's version is deliberately ≠ 1: the fixture default everywhere
  // else is 1, so a hardcoded `1` in `approveCommand` could never be told apart
  // from the real value. The controller must pass the exact version it read.
  const command = (overrides: Partial<StreamDeckCommand> = {}): StreamDeckCommand => ({
    decision_id: "dec-answer",
    version: 7,
    ticket: { identifier: "agent-6" },
    question: "Ship the change?",
    context: { short: "The checks are green." },
    options: [
      { id: "ship", label: "Ship it", description: "Merge and deploy now." },
      { id: "wait", label: "Wait", description: "Hold until tomorrow." },
    ],
    status: "open",
    answer: null,
    created_at: "2026-08-18T00:00:00Z",
    ...overrides,
  });

  /** Focuses the agent, opens Commands, and lands on the Command's detail view. */
  const answerHarness = (commandOverrides: Partial<StreamDeckCommand> = {}, voiceOver: Partial<ControllerVoice> = {}) => {
    const answerCommand = vi.fn();
    let text = "";
    const voice: ControllerVoice & { say(value: string): void } = {
      hold: vi.fn(),
      release: vi.fn(),
      message: () => text,
      hasMessage: () => text !== "",
      clear: vi.fn(() => { text = ""; }),
      dispose: vi.fn(),
      microphones: () => [],
      refresh: vi.fn(),
      selectedDeviceId: () => null,
      select: vi.fn(),
      say: (value: string) => { text = value; },
      ...voiceOver,
    };
    const controller = createPhysicalController({
      grid,
      channel: () => ({ focus: vi.fn(), control: vi.fn(), say: vi.fn(), commandsPage: vi.fn(), answerCommand }),
      voice: () => voice,
      stateChanged: vi.fn(),
    });
    controller.handleReport(keyReport(3, true));
    controller.handleReport(keyReport(3, false));
    controller.handleReport(keyReport(4, true));
    controller.handleReport(keyReport(4, false));
    const page: StreamDeckCommandsPage = { items: [command(commandOverrides)], has_next: false, next_cursor: null, total: 1 };
    controller.setCommands(page);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    expect(controller.state()).toMatchObject({ mode: "commands", commandsView: "detail", selectedCommand: { decision_id: "dec-answer" } });
    return { controller, voice, answerCommand };
  };

  // `approveCommand` is fire-and-forget and awaits the SHA-256 idempotency-key
  // digest before it calls the channel, so a negative assertion must wait out
  // that async hop before it can trust "not called". Without this wait, a
  // guard mutant that sends the answer *late* would land after the assertion
  // and pass green.
  const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

  it("approves a selected option with the exact decision, version, idempotency key and payload", async () => {
    const { controller, answerCommand } = answerHarness();
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    expect(controller.state().selectedOption).toBe(0);

    controller.handleReport(dialButton(3));
    const expected = { option_id: "ship" };
    await vi.waitFor(() => {
      expect(answerCommand).toHaveBeenCalledWith("dec-answer", 7, expect.stringMatching(/^sd_[0-9a-f]{32}$/), expected);
    });
    // The idempotency key is the SHA-256-derived key for this decision and
    // answer, not a placeholder — the client's own derivation is what ships.
    expect(answerCommand.mock.calls[0][2]).toBe(await commandIdempotencyKey("dec-answer", expected));

    // The selection is consumed by the answer: a second dial D press must not
    // re-send (a stale selection must never become a second decision).
    expect(controller.state().selectedOption).toBeNull();
    controller.handleReport(dialButton(3));
    await settle();
    expect(answerCommand).toHaveBeenCalledTimes(1);
  });

  it("approves a spoken custom response with the exact decision, version, idempotency key and payload", async () => {
    const { controller, voice, answerCommand } = answerHarness();
    controller.handleReport(keyReport(4, true));
    controller.handleReport(keyReport(4, false));
    voice.say("Hold everything — verify first.");
    controller.refreshVoice();
    expect(controller.state().commandDictation).toBe(true);

    controller.handleReport(keyReport(5, true));
    controller.handleReport(keyReport(5, false));
    const expected = { custom_response: "Hold everything — verify first." };
    await vi.waitFor(() => {
      expect(answerCommand).toHaveBeenCalledWith("dec-answer", 7, expect.stringMatching(/^sd_[0-9a-f]{32}$/), expected);
    });
    expect(answerCommand.mock.calls[0][2]).toBe(await commandIdempotencyKey("dec-answer", expected));
  });

  it("sends nothing when no option or dictation is armed", async () => {
    const { controller, answerCommand } = answerHarness();
    controller.handleReport(dialButton(3));
    await settle();
    expect(answerCommand).not.toHaveBeenCalled();
  });

  it("sends nothing when the selected option's id is empty", async () => {
    // An option with an empty id is not an answer: `{ option_id: "" }` must
    // never reach the channel, or a broken projection would read as "ship".
    const { controller, answerCommand } = answerHarness({
      options: [{ id: "", label: "Empty", description: "No id." }],
    });
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    expect(controller.state().selectedOption).toBe(0);
    controller.handleReport(dialButton(3));
    await settle();
    expect(answerCommand).not.toHaveBeenCalled();
  });

  it("refuses an empty dictation buffer as a custom response", async () => {
    // A voice port that reports a message but returns empty text must not turn
    // into `{ custom_response: "" }`: the `response !== ""` guard decides the
    // answer is unarmed, so nothing reaches the channel.
    const { controller, answerCommand } = answerHarness({}, { hasMessage: () => true, message: () => "" });
    controller.refreshVoice();
    expect(controller.state().commandDictation).toBe(true);
    controller.handleReport(keyReport(5, true));
    controller.handleReport(keyReport(5, false));
    await settle();
    expect(answerCommand).not.toHaveBeenCalled();
  });
});
