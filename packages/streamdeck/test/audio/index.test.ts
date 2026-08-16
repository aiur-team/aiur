import { describe, expect, it } from "vitest";
import * as audio from "../../src/audio/index.js";
import { VOICE_UNCONFIGURED_REASON } from "../../src/audio/index.js";

describe("the extraction boundary", () => {
  it("re-exports everything a host needs, so nothing imports deeper", () => {
    // Consumers import from here and nowhere deeper: that is what makes moving
    // the directory into its own package a `git mv` plus one specifier change.
    // A name dropped from this list silently forces a deep import somewhere.
    expect(Object.keys(audio).sort()).toEqual(
      [
        "CAPTURE_LATENCY_MS",
        "DEFAULT_PCM_FORMAT",
        "FIRST_BYTE_TIMEOUT_MS",
        "FLOOR_DBFS",
        "PACTL",
        "PAREC",
        "PW_DUMP",
        "RUN_TIMEOUT_MS",
        "TARGET_FRAME_BYTES",
        "VOICE_UNCONFIGURED_REASON",
        "captureArgs",
        "createChunkAggregator",
        "createFilePreferenceStore",
        "createMicPreferences",
        "createNodeSystem",
        "createRelayTranscriber",
        "createTranscriptBuffer",
        "createUnavailableTranscriber",
        "createVoiceSession",
        "createWaveformScroll",
        "dbfsToFill",
        "decodePcm16",
        "listMicrophones",
        "measure",
        "peak",
        "rms",
        "startCapture",
        "toDbfs",
      ].sort(),
    );
  });

  it("exposes the Node adapters as callable host wiring", () => {
    expect(typeof audio.createNodeSystem).toBe("function");
    expect(typeof audio.createFilePreferenceStore).toBe("function");
    expect(audio.RUN_TIMEOUT_MS).toBe(5_000);
  });

  it("carries no provider credential and no provider endpoint", () => {
    // Aiur performs the ElevenLabs call. A key, URL or model id reappearing on
    // this surface would mean the sidecar had grown a second place to hold one.
    for (const name of Object.keys(audio)) {
      expect(name).not.toMatch(/ELEVENLABS|API_KEY|SOCKET|Socket/);
    }
  });
});

describe("the unconfigured reason", () => {
  it("names Aiur, because that is where the key would be fixed", () => {
    // An operator told only "no API key" would search the sidecar's config,
    // which by design holds nothing to find.
    expect(VOICE_UNCONFIGURED_REASON).toBe("Aiur has no ElevenLabs API key - transcription is off");
  });

  it("produces an unavailable transcriber that still lets the meters run", () => {
    const relay = audio.createRelayTranscriber({
      port: { start: () => {}, audio: () => {}, stop: () => {} },
      unavailableReason: VOICE_UNCONFIGURED_REASON,
    });
    expect(relay.transcriber.available).toBe(false);
    expect(relay.transcriber.unavailableReason).toBe(VOICE_UNCONFIGURED_REASON);
  });
});
