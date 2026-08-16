/**
 * View model for the voice panel — the 800x100 touch strip while the mic is
 * held.
 *
 * ## The load-bearing property
 *
 * **The waveform and the decibel bar are computed on this machine and never
 * wait on Aiur.** `session.ts`'s `onChunk` decodes each 20 ms capture chunk,
 * calls `measure()` and `waveform.push()` immediately, and only afterwards
 * hands the bytes to the aggregator that reaches the network. Everything this
 * module reads — `columns`, `dbfs`, `holding` — comes from that local path, so
 * the "is my microphone working?" signal is bounded by the 20 ms capture
 * latency and by nothing else.
 *
 * The direct consequence, and the reason the split was worth making: when Aiur
 * has no API key the meters keep moving. `status` says why transcription is
 * off, and the waveform underneath it is still live. A missing key must never
 * blank the trace — that would turn a configuration problem into what looks
 * like a dead microphone.
 *
 * Only `text` round-trips.
 */

import { dbfsToFill, type WaveformColumn } from "./audio/index.js";

/**
 * Columns the panel draws.
 *
 * The strip is 800px wide and the trace occupies most of it, so 180 columns is
 * a little over 4px each — wide enough to read as a waveform rather than as
 * noise. At the session's 50 ms per column that is nine seconds of history,
 * which comfortably spans a spoken instruction.
 */
export const VOICE_WAVEFORM_COLUMNS = 180;

/** Prompt shown when the mic is configured but not currently held. */
export const VOICE_HOLD_PROMPT = "HOLD MIC TO TALK";

/** Shown while capture is running. */
export const VOICE_LISTENING = "LISTENING";

export interface VoicePanelData {
  /** Oldest column left, newest right, always {@link VOICE_WAVEFORM_COLUMNS} long. */
  readonly columns: readonly WaveformColumn[];
  /** 0..1 height of the decibel bar, linear in decibels. */
  readonly fill: number;
  readonly dbfs: number;
  /** Settled text plus the live partial. */
  readonly text: string;
  /** The operator-facing line under the trace. */
  readonly status: string;
  readonly holding: boolean;
}

export interface VoicePanelInput {
  readonly columns: readonly WaveformColumn[];
  readonly dbfs: number;
  readonly text: string;
  readonly holding: boolean;
  /** Why transcription is off, or null when it is available. */
  readonly unavailableReason: string | null;
}

const SILENT: WaveformColumn = Object.freeze({ min: 0, max: 0 });

/**
 * Exactly {@link VOICE_WAVEFORM_COLUMNS} columns, newest kept.
 *
 * The session is constructed with this width so the normal case is a pass
 * through, but the panel's geometry is fixed and a short array would draw a
 * trace that stops partway across the strip. A long one is trimmed from the
 * *left*, because the right-hand end is the newest audio and is the end the
 * operator is watching.
 */
const normalize = (columns: readonly WaveformColumn[]): readonly WaveformColumn[] => {
  if (columns.length === VOICE_WAVEFORM_COLUMNS) return columns;
  if (columns.length > VOICE_WAVEFORM_COLUMNS) return columns.slice(columns.length - VOICE_WAVEFORM_COLUMNS);
  const padding = new Array<WaveformColumn>(VOICE_WAVEFORM_COLUMNS - columns.length).fill(SILENT);
  return [...padding, ...columns];
};

/**
 * The operator-facing status line.
 *
 * The unavailable reason wins over both other states, because it is the only
 * one that asks the operator to go and change something. It does not suppress
 * the meters — see this module's header.
 */
const statusLine = (input: VoicePanelInput): string => {
  const reason = input.unavailableReason ?? "";
  if (reason !== "") return reason;
  return input.holding ? VOICE_LISTENING : VOICE_HOLD_PROMPT;
};

export function voicePanel(input: VoicePanelInput): VoicePanelData {
  return {
    columns: normalize(input.columns),
    // The bar is linear in decibels, not in amplitude: `dbfsToFill` already
    // does that mapping and re-deriving it from an amplitude here would spend
    // the bar's whole travel in the top few decibels and read as broken.
    fill: dbfsToFill(input.dbfs),
    dbfs: input.dbfs,
    text: input.text,
    status: statusLine(input),
    holding: input.holding,
  };
}
