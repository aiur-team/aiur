import { describe, expect, it, vi } from "vitest";
import * as audio from "../../src/audio/index.js";
import { ELEVENLABS_REALTIME_MODEL, NO_API_KEY_REASON, selectTranscriber } from "../../src/audio/index.js";
import type { SocketLike } from "../../src/audio/index.js";

const socketStub = (): SocketLike => ({
  send: vi.fn(),
  close: vi.fn(),
  onopen: null,
  onmessage: null,
  onerror: null,
  onclose: null,
});

describe("the extraction boundary", () => {
  it("re-exports everything a host needs, so nothing imports deeper", () => {
    // Consumers import from here and nowhere deeper: that is what makes moving
    // the directory into its own package a `git mv` plus one specifier change.
    // A name dropped from this list silently forces a deep import somewhere.
    expect(Object.keys(audio).sort()).toEqual(
      [
        "CAPTURE_LATENCY_MS",
        "DEFAULT_PCM_FORMAT",
        "ELEVENLABS_REALTIME_MODEL",
        "ELEVENLABS_REALTIME_URL",
        "FIRST_BYTE_TIMEOUT_MS",
        "FLOOR_DBFS",
        "NO_API_KEY_REASON",
        "PACTL",
        "PAREC",
        "PW_DUMP",
        "RUN_TIMEOUT_MS",
        "TARGET_FRAME_BYTES",
        "captureArgs",
        "createChunkAggregator",
        "createElevenLabsTranscriber",
        "createMicPreferences",
        "createNodeSocket",
        "createNodeSystem",
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
        "selectTranscriber",
        "startCapture",
        "toDbfs",
      ].sort(),
    );
  });

  it("exposes the Node adapters as callable host wiring", () => {
    expect(typeof audio.createNodeSystem).toBe("function");
    expect(typeof audio.createNodeSocket).toBe("function");
    expect(audio.RUN_TIMEOUT_MS).toBe(5_000);
  });
});

describe("transcriber selection", () => {
  it("degrades to an unavailable transcriber when the key is null", () => {
    const transcriber = selectTranscriber({ apiKey: null, socket: () => socketStub() });
    expect(transcriber.available).toBe(false);
    expect(transcriber.unavailableReason).toBe(NO_API_KEY_REASON);
  });

  it("degrades to an unavailable transcriber when the key is absent", () => {
    const transcriber = selectTranscriber({ apiKey: undefined, socket: () => socketStub() });
    expect(transcriber.available).toBe(false);
    expect(transcriber.unavailableReason).toBe(NO_API_KEY_REASON);
  });

  it("treats a blank key as no key rather than trying to authenticate with it", () => {
    const transcriber = selectTranscriber({ apiKey: "", socket: () => socketStub() });
    expect(transcriber.available).toBe(false);
    expect(transcriber.unavailableReason).toBe(NO_API_KEY_REASON);
  });

  it("returns a live transcriber for a configured key", () => {
    const socket = vi.fn(() => socketStub());
    const transcriber = selectTranscriber({ apiKey: "xi-secret", socket });

    expect(transcriber.available).toBe(true);
    expect(transcriber.unavailableReason).toBeNull();

    transcriber.open({ onTranscript: vi.fn(), onError: vi.fn() });
    const [url, headers] = socket.mock.calls[0] as unknown as [string, Record<string, string>];
    expect(new URL(url).searchParams.get("model_id")).toBe(ELEVENLABS_REALTIME_MODEL);
    expect(headers).toEqual({ "xi-api-key": "xi-secret" });
  });

  it("defaults the language and rate when the caller does not override them", () => {
    const socket = vi.fn(() => socketStub());
    selectTranscriber({ apiKey: "xi-secret", socket }).open({ onTranscript: vi.fn(), onError: vi.fn() });

    const url = new URL((socket.mock.calls[0] as unknown as [string])[0]);
    expect(url.searchParams.get("language_code")).toBe("eng");
    expect(url.searchParams.get("audio_format")).toBe("pcm_16000");
  });

  it("passes an explicit language and sample rate through", () => {
    const socket = vi.fn(() => socketStub());
    selectTranscriber({ apiKey: "xi-secret", socket, languageCode: "fra", sampleRate: 48_000 }).open({
      onTranscript: vi.fn(),
      onError: vi.fn(),
    });

    const url = new URL((socket.mock.calls[0] as unknown as [string])[0]);
    expect(url.searchParams.get("language_code")).toBe("fra");
    expect(url.searchParams.get("audio_format")).toBe("pcm_48000");
  });

  it("passes each override independently of the other", () => {
    const languageOnly = vi.fn(() => socketStub());
    selectTranscriber({ apiKey: "xi-secret", socket: languageOnly, languageCode: "deu" }).open({
      onTranscript: vi.fn(),
      onError: vi.fn(),
    });
    const languageUrl = new URL((languageOnly.mock.calls[0] as unknown as [string])[0]);
    expect(languageUrl.searchParams.get("language_code")).toBe("deu");
    expect(languageUrl.searchParams.get("audio_format")).toBe("pcm_16000");

    const rateOnly = vi.fn(() => socketStub());
    selectTranscriber({ apiKey: "xi-secret", socket: rateOnly, sampleRate: 8_000 }).open({
      onTranscript: vi.fn(),
      onError: vi.fn(),
    });
    const rateUrl = new URL((rateOnly.mock.calls[0] as unknown as [string])[0]);
    expect(rateUrl.searchParams.get("language_code")).toBe("eng");
    expect(rateUrl.searchParams.get("audio_format")).toBe("pcm_8000");
  });
});
