/**
 * ElevenLabs streaming text-to-speech, behind the provider-agnostic contract.
 *
 * Transcription (`elevenlabs.ts`) is a bidirectional websocket because audio
 * streams as it is captured. TTS is the inverse shape: a POST that streams
 * encoded audio back, so the streaming endpoint is the right primitive here.
 * Requesting raw PCM (`pcm_44100`) lets the playback adapter pipe bytes
 * straight to the device with no decoder on the host.
 *
 * Protocol reference:
 * https://elevenlabs.io/docs/api-reference/text-to-speech
 *
 * The API key travels as a request header, never in the URL, for the same
 * reason the transcription path does: a URL is the thing that ends up in
 * logs and error messages. Nothing here prints the key.
 */

import type { TTSInput, TTSProvider } from "./tts.js";
import { createNodeFetch } from "./node-fetch.js";
import { prepareAiurForSpeech } from "../aiur-speech.js";

/** The streaming endpoint; `output_format` is appended as a query param. */
export const ELEVENLABS_TTS_URL = "https://api.elevenlabs.io/v1/text-to-speech";
/** Fast, cheap model: the right latency profile for a conversation. */
export const ELEVENLABS_TTS_MODEL = "eleven_flash_v2_5";
/** Raw 44.1 kHz s16le, so the playback adapter needs no decoder. */
export const DEFAULT_OUTPUT_FORMAT = "pcm_44100";

/** Minimal fetch response shape, redeclared so the stack owns no Node types. */
export interface FetchResponse {
  readonly ok: boolean;
  readonly status: number;
  /** The response body as a byte stream. Only meaningful when `ok`. */
  stream(): AsyncIterable<Uint8Array>;
}

/** The HTTP port the TTS provider needs: POST a JSON body, get a response. */
export type FetchLike = (
  url: string,
  init: {
    readonly method: string;
    readonly headers: Readonly<Record<string, string>>;
    readonly body: string;
  },
) => Promise<FetchResponse>;

export interface ElevenLabsTTSOptions {
  readonly apiKey: string;
  readonly baseUrl?: string;
  readonly model?: string;
  readonly outputFormat?: string;
  /** Injected so tests stub the network without a real key. Defaults to the Node fetch adapter. */
  readonly fetch?: FetchLike;
}

export function createElevenLabsTTSProvider(options: ElevenLabsTTSOptions): TTSProvider {
  const baseUrl = options.baseUrl ?? ELEVENLABS_TTS_URL;
  const model = options.model ?? ELEVENLABS_TTS_MODEL;
  const outputFormat = options.outputFormat ?? DEFAULT_OUTPUT_FORMAT;
  const fetchAudio = options.fetch ?? createNodeFetch;

  return {
    available: true,
    unavailableReason: null,
    async *synthesizeStream(input: TTSInput): AsyncIterable<Uint8Array> {
      const format = input.format ?? outputFormat;
      const modelId = input.model ?? model;
      const url = `${baseUrl}/${encodeURIComponent(input.voiceId)}/stream?output_format=${encodeURIComponent(format)}`;
      const response = await fetchAudio(url, {
        method: "POST",
        headers: {
          "xi-api-key": options.apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ text: prepareAiurForSpeech(input.text), model_id: modelId }),
      });
      if (!response.ok) {
        throw new Error(`ElevenLabs TTS failed with status ${response.status}`);
      }
      yield* response.stream();
    },
  };
}
