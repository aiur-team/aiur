import { discoverMicrophones, discoverSpeakers } from "./audio/devices.js";
import type { SystemPort } from "./audio/system.js";
import { spawnLineSource, type SpawnLike } from "./line-source.js";
import type { DeckDevices } from "./deck-settings.js";

/** Pulse subscribe reports PipeWire compatibility-node changes without polling. */
export function createDeviceInventory(options: {
  system: SystemPort;
  spawn: SpawnLike;
  instances: readonly string[];
  legacyMicId: string | null;
  changed(devices: DeckDevices): void;
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
}) {
  let stopped = false;
  let running = false;
  let again = false;
  let retry: unknown = null;
  let source: { stop(): void } | null = null;
  const refresh = async (): Promise<void> => {
    if (stopped) return;
    if (running) { again = true; return; }
    running = true;
    const [mics, speakers] = await Promise.all([discoverMicrophones(options.system), discoverSpeakers(options.system)]);
    running = false;
    if (stopped) return;
    options.changed({ mics: mics.devices, speakers: speakers.devices, availability: { mics: mics.available, speakers: speakers.available }, instances: options.instances, ...(options.legacyMicId ? { legacy_mic_id: options.legacyMicId } : {}) });
    if (again) { again = false; await refresh(); }
  };
  const monitor = (): void => {
    let ended = false;
    source = spawnLineSource(options.spawn, "pactl", ["subscribe"], {
      onLine: (line) => { if (/\bon (source|sink|card)\b/.test(line)) void refresh(); },
      onEnd: () => {
        if (stopped || ended) return;
        ended = true;
        retry = options.setTimer(() => { retry = null; monitor(); void refresh(); }, 5000);
      },
    });
  };
  monitor();
  return {
    refresh,
    stop(): void { stopped = true; source?.stop(); if (retry !== null) options.clearTimer(retry); },
  };
}
