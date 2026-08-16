import { describe, expect, it } from "vitest";

import {
  VOICE_HOLD_PROMPT,
  VOICE_LISTENING,
  VOICE_WAVEFORM_COLUMNS,
  voicePanel,
  type VoicePanelInput,
} from "../src/voicePanel.js";
import { createVoiceSession, createWaveformScroll, dbfsToFill, type WaveformColumn } from "../src/audio/index.js";

const columns = (count: number): WaveformColumn[] =>
  Array.from({ length: count }, (_, index) => ({ min: -index / count, max: index / count }));

const input = (over: Partial<VoicePanelInput> = {}): VoicePanelInput => ({
  columns: columns(VOICE_WAVEFORM_COLUMNS),
  dbfs: -20,
  text: "",
  holding: false,
  unavailableReason: null,
  ...over,
});

describe("voicePanel", () => {
  it("passes a full-width column set straight through, newest last", () => {
    const full = columns(VOICE_WAVEFORM_COLUMNS);
    expect(voicePanel(input({ columns: full })).columns).toBe(full);
  });

  it("pads a short column set on the left so the trace is always full width", () => {
    const panel = voicePanel(input({ columns: columns(3) }));
    expect(panel.columns).toHaveLength(VOICE_WAVEFORM_COLUMNS);
    // The oldest end is padded with silence; the newest audio stays on the right.
    expect(panel.columns[0]).toEqual({ min: 0, max: 0 });
    expect(panel.columns.slice(-3)).toEqual(columns(3));
  });

  it("keeps the newest columns when given more than fit", () => {
    const many = columns(VOICE_WAVEFORM_COLUMNS + 10);
    const panel = voicePanel(input({ columns: many }));
    expect(panel.columns).toHaveLength(VOICE_WAVEFORM_COLUMNS);
    expect(panel.columns[VOICE_WAVEFORM_COLUMNS - 1]).toEqual(many[many.length - 1]);
  });

  // The bar is linear in decibels. A bar re-mapped to amplitude would spend
  // almost its whole travel in the top few decibels and read as broken.
  it("takes the bar fill straight from dbfsToFill", () => {
    for (const dbfs of [-60, -30, -12, 0]) {
      expect(voicePanel(input({ dbfs })).fill).toBe(dbfsToFill(dbfs));
    }
    expect(voicePanel(input({ dbfs: -30 })).dbfs).toBe(-30);
  });

  it("says LISTENING while held and prompts otherwise", () => {
    expect(voicePanel(input({ holding: true })).status).toBe(VOICE_LISTENING);
    expect(voicePanel(input({ holding: false })).status).toBe(VOICE_HOLD_PROMPT);
    expect(voicePanel(input({ holding: true })).holding).toBe(true);
  });

  it("carries the buffered text verbatim", () => {
    expect(voicePanel(input({ text: "run the tests again" })).text).toBe("run the tests again");
  });

  /**
   * The whole point of Aiur holding the API key: transcription can be off while
   * the microphone is fine. The reason replaces the prompt, and the meters are
   * untouched — a blank waveform here would read as a dead microphone and send
   * the operator hunting for a hardware fault.
   */
  it("shows the unavailable reason without blanking the meters", () => {
    const reason = "Aiur has no ElevenLabs API key - transcription is off";
    const panel = voicePanel(input({ unavailableReason: reason, holding: true, dbfs: -12 }));
    expect(panel.status).toBe(reason);
    expect(panel.fill).toBe(dbfsToFill(-12));
    expect(panel.columns).toHaveLength(VOICE_WAVEFORM_COLUMNS);
    expect(panel.columns.some((column) => column.max !== 0)).toBe(true);
  });

  it("treats an empty reason as available", () => {
    expect(voicePanel(input({ unavailableReason: "", holding: true })).status).toBe(VOICE_LISTENING);
  });
});

/**
 * The load-bearing property, demonstrated end to end rather than asserted in
 * prose: a session with **no transport at all** — a transcriber that never
 * opens, so nothing can leave the machine — still produces a moving waveform
 * and a rising decibel bar from captured bytes alone.
 */
describe("the meters are local", () => {
  it("moves the waveform and the decibel bar with no network in the picture", () => {
    let emit: ((pcm: Uint8Array) => void) | null = null;
    const session = createVoiceSession({
      system: { run: async () => "", spawn: () => { throw new Error("unused"); } },
      // `available: false` is the "Aiur has no key" case: `open` is never
      // called, so this session has no path to any network at all.
      transcriber: { available: false, unavailableReason: "no key", open: () => { throw new Error("must not open"); } },
      deviceId: null,
      waveformWidth: VOICE_WAVEFORM_COLUMNS,
      onUpdate: () => undefined,
      onError: () => undefined,
      capture: (_options, handlers) => {
        emit = handlers.onChunk;
        return { stop: () => undefined };
      },
    });

    const quiet = voicePanel({
      columns: session.waveform(),
      dbfs: session.level().dbfs,
      text: session.text(),
      holding: session.holding,
      unavailableReason: session.unavailableReason,
    });
    expect(quiet.fill).toBe(0);

    session.hold();
    // 1 kHz-ish full-scale-ish tone as raw s16le bytes, straight into capture.
    const loud = new Uint8Array(16_000 * 2);
    for (let sample = 0; sample < 16_000; sample += 1) {
      const value = Math.round(Math.sin((sample / 16) * Math.PI * 2) * 20_000);
      loud[sample * 2] = value & 0xff;
      loud[sample * 2 + 1] = (value >> 8) & 0xff;
    }
    (emit as unknown as (pcm: Uint8Array) => void)(loud);

    const live = voicePanel({
      columns: session.waveform(),
      dbfs: session.level().dbfs,
      text: session.text(),
      holding: session.holding,
      unavailableReason: session.unavailableReason,
    });
    expect(live.fill).toBeGreaterThan(0.5);
    expect(live.columns.some((column) => column.max > 0.3 && column.min < -0.3)).toBe(true);
    // Nothing came back from anywhere, and it did not have to.
    expect(live.text).toBe("");
    expect(live.status).toBe("no key");
    session.dispose();
  });

  it("orders columns oldest-left so the trace travels left to right", () => {
    const scroll = createWaveformScroll(VOICE_WAVEFORM_COLUMNS, 2);
    scroll.push(Float32Array.from([0.1, 0.1]));
    scroll.push(Float32Array.from([0.9, 0.9]));
    const panel = voicePanel(input({ columns: scroll.columns() }));
    // Newest sample is the right-hand column; the one before it sits to its left.
    expect(panel.columns[VOICE_WAVEFORM_COLUMNS - 1].max).toBeCloseTo(0.9);
    expect(panel.columns[VOICE_WAVEFORM_COLUMNS - 2].max).toBeCloseTo(0.1);
  });
});
