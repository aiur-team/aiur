import { startCapture, type CaptureHandlers } from "./audio/capture.js";
import { createPacatPlayback, type PacatPlaybackOptions } from "./audio/node-playback.js";
import type { SystemPort } from "./audio/system.js";
import { resolveAudioDevice, type DeckDevices, type DeckSettings } from "./deck-settings.js";

/** Audio ports resolve saved daemon choices immediately before opening devices. */
export function createDeckAudio(options: {
  settings(): DeckSettings | null;
  devices(): DeckDevices;
  system: SystemPort;
  playback?: PacatPlaybackOptions;
}) {
  return {
    capture(handlers: CaptureHandlers) {
      const deviceId = resolveAudioDevice(options.settings()?.mic_id ?? null, options.devices().mics);
      return startCapture({ system: options.system, deviceId }, handlers);
    },
    playback() {
      const deviceId = resolveAudioDevice(options.settings()?.speaker_id ?? null, options.devices().speakers);
      return createPacatPlayback({ ...options.playback, args: deviceId === null ? [] : [`--device=${deviceId}`] });
    },
  };
}
