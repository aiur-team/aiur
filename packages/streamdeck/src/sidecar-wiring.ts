/**
 * Stateless helpers of the process entry point. Split from `main.ts`, and
 * excluded from coverage for the same reason: wiring with nothing to decide.
 */
import { homedir } from "node:os";
import path from "node:path";
import process from "node:process";

import type { AudioDevice } from "./audio/index.js";
import type { StreamDeckGrid } from "./channel.js";
import type { ControllerState } from "./controller.js";
import { debugEnabled } from "./debug.js";
import { debug } from "./hid-device.js";
import { decodeInputReport } from "./input.js";
import type { LogEntry } from "./runtime.js";
import type { PhysicalSurfaceState } from "./surface.js";
import type { VoicePanelInput } from "./voicePanel.js";

/**
 * Where the remembered microphone is kept.
 *
 * `XDG_CONFIG_HOME` when the desktop sets it, `~/.config` otherwise — the same
 * rule every other tool on this box follows, so the file lands where an
 * operator would look for it and where their dotfile backup already reaches.
 */
export const micPreferencePath = (): string =>
  path.join(process.env.XDG_CONFIG_HOME ?? path.join(homedir(), ".config"), "aiur", "streamdeck-mic.json");

/**
 * Bucket histogram for the trace. Key colour is derived entirely from the
 * bucket, so "every key looks grey" is only diagnosable if the trace says
 * whether the fleet is genuinely all queued/paused (both grey by contract) or
 * whether the bucket is failing to arrive.
 */
export const bucketCounts = (grid: StreamDeckGrid): Record<string, number> => {
  const counts: Record<string, number> = {};
  for (const agent of grid.agents) {
    const bucket = typeof agent.bucket === "string" ? agent.bucket : "(missing)";
    counts[bucket] = (counts[bucket] ?? 0) + 1;
  }
  return counts;
};

/** Traces a report's decoded controls; a no-op unless debug tracing is on. */
export const traceInput = (data: Uint8Array): void => {
  if (debugEnabled(process.env.AIUR_STREAMDECK_DEBUG)) {
    const decoded = decodeInputReport(data);
    debug("input.decoded", {
      count: decoded.length,
      controls: decoded.map((input) =>
        input.type === "encoder-turn"
          ? `turn${input.index}:${input.ticks}`
          : `${input.type === "key" ? "key" : "dial"}${input.index}:${input.pressed ? "down" : "up"}`,
      ),
    });
  }
};

/** The surface's view of the controller state plus the live voice readings. */
export const surfaceState = (
  current: ControllerState,
  microphones: readonly AudioDevice[],
  voice: VoicePanelInput | undefined,
): PhysicalSurfaceState => ({
  mode: current.mode,
  focusedIdentifier: current.focusedIdentifier,
  micHeld: current.micHeld,
  columnOffset: current.columnOffset,
  providerOffset: current.providerOffset,
  transcriptRows: current.transcriptRows,
  eventLines: current.eventLines,
  eventOffset: current.eventOffset,
  eventHasPrevious: current.eventHasPrevious,
  eventHasNext: current.eventHasNext,
  chatHasPrevious: current.chatHasPrevious,
  chatHasNext: current.chatHasNext,
  selectedEvent: current.selectedEvent,
  hasTranscript: current.hasTranscript,
  implementQueued: current.implementQueued,
  microphones,
  selectedMicId: current.selectedMicId,
  micOffset: current.micOffset,
  voice,
  commandsPage: current.commandsPage,
  commandsView: current.commandsView,
  historyOffset: current.historyOffset,
  selectedCommand: current.selectedCommand,
  optionOffset: current.optionOffset,
  selectedOption: current.selectedOption,
  commandDictation: current.commandDictation,
  commandsError: current.commandsError,
});

/** Routes a runtime log entry to the matching console level. */
export const logLine = ({ level, message, cause }: LogEntry): void => {
  const line = `[streamdeck] ${message}`;
  if (level === "error") {
    console.error(line, cause ?? "");
  } else if (level === "warn") {
    console.warn(line, cause ?? "");
  } else {
    console.info(line);
  }
};
