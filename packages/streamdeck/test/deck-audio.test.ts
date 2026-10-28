import { expect, it, vi } from "vitest";
import { createDeckAudio } from "../src/deck-audio.js";
import type { DeckSettings } from "../src/deck-settings.js";

it("opens the first microphone/speaker when saved devices are missing, then reuses restored devices", () => {
  let mics = [{ id: "first-mic", label: "First" }];
  const settings: DeckSettings = { mic_id: "saved-mic", speaker_id: "saved-speaker", default_view: "ticket", default_sort: "state", brightness: null, dim_after_seconds: 0, instance: null, alerts: {} };
  const spawn = vi.fn((_command: string, _args: readonly string[]) => { void _command; void _args; return { onData: vi.fn(), onExit: vi.fn(), kill: vi.fn() }; });
  const playbackSpawn = vi.fn((_command: string, _args: readonly string[]) => { void _command; void _args; return { stdin: { write: vi.fn(() => true), end: vi.fn(), once: vi.fn(), on: vi.fn() }, onExit: vi.fn() }; });
  const audio = createDeckAudio({ settings: () => settings, devices: () => ({ mics, speakers: [{ id: "first-speaker", label: "Speaker" }], instances: [] }), system: { run: vi.fn(), spawn }, playback: { spawn: playbackSpawn } });
  const capture = audio.capture({ onChunk: vi.fn(), onError: vi.fn() });
  expect(spawn).toHaveBeenLastCalledWith("parec", expect.arrayContaining(["--device=first-mic"]));
  capture.stop();
  audio.playback();
  expect(playbackSpawn).toHaveBeenLastCalledWith("pacat", expect.arrayContaining(["--device=first-speaker"]));
  mics = [...mics, { id: "saved-mic", label: "Restored" }];
  audio.capture({ onChunk: vi.fn(), onError: vi.fn() }).stop();
  expect(spawn).toHaveBeenLastCalledWith("parec", expect.arrayContaining(["--device=saved-mic"]));
  expect(settings.mic_id).toBe("saved-mic");
});

it("uses host defaults with no daemon settings or attached devices", () => {
  const spawn = vi.fn((_command: string, _args: readonly string[]) => { void _command; void _args; return { onData: vi.fn(), onExit: vi.fn(), kill: vi.fn() }; });
  const playbackSpawn = vi.fn((_command: string, _args: readonly string[]) => { void _command; void _args; return { stdin: { write: vi.fn(() => true), end: vi.fn(), once: vi.fn(), on: vi.fn() }, onExit: vi.fn() }; });
  const audio = createDeckAudio({ settings: () => null, devices: () => ({ mics: [], speakers: [], instances: [] }), system: { run: vi.fn(), spawn }, playback: { spawn: playbackSpawn } });
  audio.capture({ onChunk: vi.fn(), onError: vi.fn() }).stop();
  expect(spawn.mock.calls[0]![1]).not.toEqual(expect.arrayContaining([expect.stringMatching(/^--device=/)]));
  audio.playback();
  expect(playbackSpawn.mock.calls[0]![1]).not.toEqual(expect.arrayContaining([expect.stringMatching(/^--device=/)]));
});
