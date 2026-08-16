import { describe, expect, it } from "vitest";
import {
  DEFAULT_OUTPUT_FORMAT,
  ELEVENLABS_TTS_MODEL,
  ELEVENLABS_TTS_URL,
  createElevenLabsTTSProvider,
  type FetchLike,
  type FetchResponse,
} from "../../src/audio/elevenlabs-tts.js";

const streamOf = (...chunks: Uint8Array[]): FetchResponse["stream"] =>
  async function* () {
    for (const chunk of chunks) {
      yield chunk;
    }
  };

interface Recording {
  readonly calls: Array<{ url: string; init: Parameters<FetchLike>[1] }>;
  readonly fetch: FetchLike;
}

function recordingFetch(options: {
  readonly ok?: boolean;
  readonly status?: number;
  readonly chunks?: Uint8Array[];
}): Recording {
  const calls: Recording["calls"] = [];
  const fetchImpl: FetchLike = async (url, init) => {
    calls.push({ url, init });
    return {
      ok: options.ok ?? true,
      status: options.status ?? 200,
      stream: streamOf(...(options.chunks ?? [])),
    };
  };
  return { calls, fetch: fetchImpl };
}

const collect = async (audio: AsyncIterable<Uint8Array>): Promise<Uint8Array[]> => {
  const chunks: Uint8Array[] = [];
  for await (const chunk of audio) {
    chunks.push(chunk);
  }
  return chunks;
};

describe("createElevenLabsTTSProvider", () => {
  it("reports available with no reason", () => {
    const provider = createElevenLabsTTSProvider({ apiKey: "k", fetch: recordingFetch({}).fetch });
    expect(provider.available).toBe(true);
    expect(provider.unavailableReason).toBeNull();
  });

  it("streams the synthesized audio in order", async () => {
    const a = new Uint8Array([1, 2]);
    const b = new Uint8Array([3]);
    const rec = recordingFetch({ chunks: [a, b] });
    const provider = createElevenLabsTTSProvider({ apiKey: "k", fetch: rec.fetch });

    const got = await collect(provider.synthesizeStream({ requestId: "r", text: "hello", voiceId: "v1" }));

    expect(got).toEqual([a, b]);
  });

  it("posts to the streaming endpoint with the key header and default model", async () => {
    const rec = recordingFetch({});
    const provider = createElevenLabsTTSProvider({ apiKey: "sekret", fetch: rec.fetch });

    await collect(provider.synthesizeStream({ requestId: "r", text: "hi", voiceId: "v1" }));

    expect(rec.calls).toHaveLength(1);
    expect(rec.calls[0].url).toBe(`${ELEVENLABS_TTS_URL}/v1/stream?output_format=${DEFAULT_OUTPUT_FORMAT}`);
    expect(rec.calls[0].init.method).toBe("POST");
    expect(rec.calls[0].init.headers["xi-api-key"]).toBe("sekret");
    expect(rec.calls[0].init.headers["Content-Type"]).toBe("application/json");
    expect(JSON.parse(rec.calls[0].init.body)).toEqual({ text: "hi", model_id: ELEVENLABS_TTS_MODEL });
  });

  it("honours baseUrl, model, and outputFormat overrides plus per-request overrides", async () => {
    const rec = recordingFetch({});
    const provider = createElevenLabsTTSProvider({
      apiKey: "k",
      baseUrl: "https://example.test/tts",
      model: "m1",
      outputFormat: "pcm_16000",
      fetch: rec.fetch,
    });

    await collect(
      provider.synthesizeStream({ requestId: "r", text: "hi", voiceId: "v2", format: "pcm_22050", model: "m2" }),
    );

    expect(rec.calls[0].url).toBe("https://example.test/tts/v2/stream?output_format=pcm_22050");
    expect(JSON.parse(rec.calls[0].init.body)).toEqual({ text: "hi", model_id: "m2" });
  });

  it("falls back to the provider output format and model when a request does not override them", async () => {
    const rec = recordingFetch({});
    const provider = createElevenLabsTTSProvider({
      apiKey: "k",
      baseUrl: "https://example.test/tts",
      model: "m1",
      outputFormat: "pcm_16000",
      fetch: rec.fetch,
    });

    await collect(provider.synthesizeStream({ requestId: "r", text: "hi", voiceId: "v2" }));

    expect(rec.calls[0].url).toBe("https://example.test/tts/v2/stream?output_format=pcm_16000");
    expect(JSON.parse(rec.calls[0].init.body)).toEqual({ text: "hi", model_id: "m1" });
  });

  it("throws with the status when the provider reports a failure", async () => {
    const rec = recordingFetch({ ok: false, status: 401 });
    const provider = createElevenLabsTTSProvider({ apiKey: "k", fetch: rec.fetch });

    await expect(collect(provider.synthesizeStream({ requestId: "r", text: "hi", voiceId: "v1" }))).rejects.toThrow(
      "ElevenLabs TTS failed with status 401",
    );
  });

  it("uses the node fetch adapter when none is injected", () => {
    // Factory only — no request is made, so no network is touched; this
    // exercises the default-transport branch of the provider construction.
    const provider = createElevenLabsTTSProvider({ apiKey: "k" });
    expect(provider.available).toBe(true);
  });
});
