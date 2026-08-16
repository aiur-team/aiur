import { describe, expect, it, vi } from "vitest";
import {
  ELEVENLABS_REALTIME_MODEL,
  ELEVENLABS_REALTIME_URL,
  FLUSH_TIMEOUT_MS,
  createElevenLabsTranscriber,
  type ElevenLabsTranscriberOptions,
  type Scheduler,
} from "../../src/audio/elevenlabs.js";
import type { SocketLike, TranscriberSession, TranscriptEvent } from "../../src/audio/stt.js";

interface SocketHarness {
  readonly socket: SocketLike & { sent: string[]; closes: number };
  /** The websocket upgrade completing, which is *not* session readiness. */
  open(): void;
  /** Delivers a server frame verbatim, so malformed text can be sent too. */
  raw(data: string): void;
  frame(value: unknown): void;
  /** The frame that actually makes the session ready to receive audio. */
  started(): void;
  error(): void;
  closed(): void;
}

const socketHarness = (): SocketHarness => {
  const socket: SocketLike & { sent: string[]; closes: number } = {
    onopen: null,
    onmessage: null,
    onerror: null,
    onclose: null,
    sent: [],
    closes: 0,
    send(data: string) {
      this.sent.push(data);
    },
    close() {
      this.closes += 1;
    },
  };
  const frame = (value: unknown): void => socket.onmessage?.({ data: JSON.stringify(value) });
  return {
    socket,
    open: () => socket.onopen?.(),
    raw: (data: string) => socket.onmessage?.({ data }),
    frame,
    started: () => frame({ message_type: "session_started" }),
    error: () => socket.onerror?.(new Error("econnreset")),
    closed: () => socket.onclose?.(),
  };
};

interface SchedulerHarness {
  readonly scheduler: Scheduler;
  readonly armed: () => boolean;
  readonly delay: () => number | null;
  readonly cancels: () => number;
  /** Runs the flush deadline by hand; no real timer is ever armed. */
  fire(): void;
}

const schedulerHarness = (): SchedulerHarness => {
  let callback: (() => void) | null = null;
  let delay: number | null = null;
  let cancels = 0;
  return {
    scheduler: (given, delayMs) => {
      callback = given;
      delay = delayMs;
      return {
        cancel: () => {
          cancels += 1;
        },
      };
    },
    armed: () => callback !== null,
    delay: () => delay,
    cancels: () => cancels,
    fire: () => callback?.(),
  };
};

/** Records the url and headers the factory was handed, then returns the fake. */
const factoryFor = (
  harness: SocketHarness,
): {
  factory: (url: string, headers: Readonly<Record<string, string>>) => SocketLike;
  calls: { url: string; headers: Readonly<Record<string, string>> }[];
} => {
  const calls: { url: string; headers: Readonly<Record<string, string>> }[] = [];
  return {
    calls,
    factory: (url, headers) => {
      calls.push({ url, headers });
      return harness.socket;
    },
  };
};

interface SessionHarness {
  readonly session: TranscriberSession;
  readonly socket: SocketHarness;
  readonly scheduler: SchedulerHarness;
  readonly events: TranscriptEvent[];
  readonly reasons: string[];
  readonly frames: () => Record<string, unknown>[];
  readonly audio: () => Record<string, unknown>[];
}

/** Opens a session on fakes, with base64 that is readable in an assertion. */
const openSession = (
  overrides: Partial<ElevenLabsTranscriberOptions> = {},
  onError?: (reason: string) => void,
): SessionHarness => {
  const socket = socketHarness();
  const scheduler = schedulerHarness();
  const events: TranscriptEvent[] = [];
  const reasons: string[] = [];
  const session = createElevenLabsTranscriber({
    apiKey: "xi-secret",
    socket: factoryFor(socket).factory,
    scheduler: scheduler.scheduler,
    encodeBase64: (bytes) => Array.from(bytes).join("-"),
    ...overrides,
  }).open({
    onTranscript: (event) => events.push(event),
    onError: (reason) => {
      reasons.push(reason);
      onError?.(reason);
    },
  });

  const frames = (): Record<string, unknown>[] =>
    socket.socket.sent.map((raw) => JSON.parse(raw) as Record<string, unknown>);

  return {
    session,
    socket,
    scheduler,
    events,
    reasons,
    frames,
    audio: () => frames().filter((frame) => frame["message_type"] === "input_audio_chunk"),
  };
};

describe("ElevenLabs realtime connection", () => {
  it("negotiates the realtime model, capture format, language and commit strategy", () => {
    const harness = socketHarness();
    const { factory, calls } = factoryFor(harness);
    createElevenLabsTranscriber({ apiKey: "xi-secret", socket: factory }).open({
      onTranscript: vi.fn(),
      onError: vi.fn(),
    });

    const url = new URL(calls[0]?.url ?? "");
    expect(`${url.protocol}//${url.host}${url.pathname}`).toBe(ELEVENLABS_REALTIME_URL);
    expect(url.searchParams.get("model_id")).toBe(ELEVENLABS_REALTIME_MODEL);
    expect(url.searchParams.get("audio_format")).toBe("pcm_16000");
    expect(url.searchParams.get("language_code")).toBe("eng");
    // VAD is what settles text while the operator is still holding the key.
    expect(url.searchParams.get("commit_strategy")).toBe("vad");
  });

  it("sends the API key as a header and never puts it in the url", () => {
    const harness = socketHarness();
    const { factory, calls } = factoryFor(harness);
    createElevenLabsTranscriber({ apiKey: "xi-secret", socket: factory }).open({
      onTranscript: vi.fn(),
      onError: vi.fn(),
    });

    expect(calls[0]?.headers).toEqual({ "xi-api-key": "xi-secret" });
    // A url is the thing that ends up in logs and error messages. ElevenLabs
    // also accepts a `token` query parameter; using it would put a credential
    // in a URL, which is precisely what this avoids.
    expect(calls[0]?.url).not.toContain("xi-secret");
    expect(calls[0]?.url).not.toContain("token");
  });

  it("honours a custom sample rate, language and base url", () => {
    const harness = socketHarness();
    const { factory, calls } = factoryFor(harness);
    createElevenLabsTranscriber({
      apiKey: "xi-secret",
      socket: factory,
      sampleRate: 48_000,
      languageCode: "fra",
      baseUrl: "wss://proxy.internal/stt",
    }).open({ onTranscript: vi.fn(), onError: vi.fn() });

    const url = new URL(calls[0]?.url ?? "");
    expect(url.host).toBe("proxy.internal");
    expect(url.pathname).toBe("/stt");
    expect(url.searchParams.get("audio_format")).toBe("pcm_48000");
    expect(url.searchParams.get("language_code")).toBe("fra");
  });

  it("advertises itself as available with no reason to show", () => {
    const transcriber = createElevenLabsTranscriber({
      apiKey: "xi-secret",
      socket: factoryFor(socketHarness()).factory,
    });
    expect(transcriber.available).toBe(true);
    expect(transcriber.unavailableReason).toBeNull();
  });
});

describe("ElevenLabs readiness", () => {
  it("does not treat the socket upgrade as readiness", () => {
    const harness = openSession();

    harness.socket.open();
    harness.session.push(new Uint8Array([1, 2]));

    // The upgrade completing is not the session being ready; audio sent in
    // that window is discarded by the server, taking the first word with it.
    expect(harness.socket.socket.sent).toEqual([]);
  });

  it("queues audio until session_started, then flushes it in order", () => {
    const harness = openSession();

    harness.session.push(new Uint8Array([1, 2]));
    harness.session.push(new Uint8Array([3, 4]));
    expect(harness.audio()).toEqual([]);

    harness.socket.started();

    expect(harness.audio()).toEqual([
      { message_type: "input_audio_chunk", audio_base_64: "1-2", commit: false, sample_rate: 16_000 },
      { message_type: "input_audio_chunk", audio_base_64: "3-4", commit: false, sample_rate: 16_000 },
    ]);
  });

  it("transmits immediately once the session has started", () => {
    const harness = openSession({ sampleRate: 48_000 });

    harness.socket.started();
    harness.session.push(new Uint8Array([5, 6]));

    // The field is `audio_base_64` — underscores before the 64 — and every
    // chunk carries commit:false until the flush seals the utterance.
    expect(harness.audio()).toEqual([
      { message_type: "input_audio_chunk", audio_base_64: "5-6", commit: false, sample_rate: 48_000 },
    ]);
  });

  it("base64-encodes chunks by default", () => {
    const socket = socketHarness();
    const session = createElevenLabsTranscriber({
      apiKey: "xi-secret",
      socket: factoryFor(socket).factory,
    }).open({ onTranscript: vi.fn(), onError: vi.fn() });

    socket.started();
    session.push(new Uint8Array([0x68, 0x69]));

    expect((JSON.parse(socket.socket.sent[0] ?? "{}") as { audio_base_64: string }).audio_base_64).toBe("aGk=");
  });
});

describe("ElevenLabs transcript frames", () => {
  it("settles text only on a committed frame", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "committed_transcript", text: "run the tests." });
    harness.socket.frame({ message_type: "committed_transcript_with_timestamps", text: "and open a PR." });

    expect(harness.events).toEqual([
      { kind: "final", text: "run the tests." },
      { kind: "final", text: "and open a PR." },
    ]);
  });

  it("treats final_transcript as revisable despite its name", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "partial_transcript", text: "run the tes" });
    harness.socket.frame({ message_type: "final_transcript", text: "run the tests" });
    harness.socket.frame({ message_type: "final_transcript_with_timestamps", text: "run the tests," });

    // This looks wrong at a glance and is not: only `committed_transcript` is
    // authoritative. Keeping a `final_transcript` as settled text would
    // duplicate the phrase once the committed version arrived.
    expect(harness.events).toEqual([
      { kind: "partial", text: "run the tes" },
      { kind: "partial", text: "run the tests" },
      { kind: "partial", text: "run the tests," },
    ]);
  });

  it("substitutes empty text for a frame whose text is not a string", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "committed_transcript", text: 42 });
    harness.socket.frame({ message_type: "partial_transcript" });

    expect(harness.events).toEqual([
      { kind: "final", text: "" },
      { kind: "partial", text: "" },
    ]);
  });

  it("ignores message types it does not act on", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "vad_score" });
    harness.socket.frame({ message_type: 99 });
    harness.socket.frame({});

    expect(harness.events).toEqual([]);
    expect(harness.reasons).toEqual([]);
  });

  it("ignores a malformed frame without tearing down a working session", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.raw("<html>502 Bad Gateway</html>");
    harness.socket.frame({ message_type: "committed_transcript", text: "still working" });

    expect(harness.reasons).toEqual([]);
    expect(harness.socket.socket.closes).toBe(0);
    expect(harness.events).toEqual([{ kind: "final", text: "still working" }]);
  });
});

describe("ElevenLabs commit flush", () => {
  it("seals the utterance with a commit frame instead of just closing", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.push(new Uint8Array([1, 2]));

    harness.session.close();

    // Closing the socket is not a documented flush; whatever the server had
    // not yet committed — the tail of what was just said — would be dropped.
    expect(harness.audio().at(-1)).toEqual({
      message_type: "input_audio_chunk",
      audio_base_64: "",
      commit: true,
      sample_rate: 16_000,
    });
    expect(harness.socket.socket.closes).toBe(0);
    expect(harness.scheduler.delay()).toBe(FLUSH_TIMEOUT_MS);
  });

  it("closes once the settled utterance arrives", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    harness.socket.frame({ message_type: "committed_transcript", text: "the last word" });

    expect(harness.events).toEqual([{ kind: "final", text: "the last word" }]);
    expect(harness.socket.socket.closes).toBe(1);
    expect(harness.scheduler.cancels()).toBe(1);
  });

  it("closes immediately when the session never started", () => {
    const harness = openSession();

    harness.session.push(new Uint8Array([1, 2]));
    harness.session.close();

    // The server has nothing to settle, so there is nothing to wait for.
    expect(harness.socket.socket.sent).toEqual([]);
    expect(harness.socket.socket.closes).toBe(1);
    expect(harness.scheduler.armed()).toBe(false);
  });

  it("ignores a second close while the flush is in flight", () => {
    const harness = openSession();
    harness.socket.started();

    harness.session.close();
    harness.session.close();

    expect(harness.audio()).toHaveLength(1);
    expect(harness.socket.socket.closes).toBe(0);
  });

  it("ignores a close after the session already ended", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();
    harness.socket.frame({ message_type: "committed_transcript", text: "done" });

    harness.session.close();

    expect(harness.socket.socket.closes).toBe(1);
  });

  it("drops audio pushed while the utterance is being sealed", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    harness.session.push(new Uint8Array([9, 9]));

    // More audio after the commit would reopen an utterance already sealed.
    expect(harness.audio()).toHaveLength(1);
  });

  it("drops audio pushed after the session ended", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();
    harness.socket.frame({ message_type: "committed_transcript", text: "done" });

    harness.session.push(new Uint8Array([9, 9]));

    expect(harness.audio()).toHaveLength(1);
  });

  it("gives up and closes when the server never settles the utterance", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    harness.scheduler.fire();

    // A silent server must not leave the connection — and the mic key — open.
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("honours a custom flush deadline", () => {
    const harness = openSession({ flushTimeoutMs: 50 });
    harness.socket.started();
    harness.session.close();
    expect(harness.scheduler.delay()).toBe(50);
  });

  it("cancels the flush deadline when the server closes first", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    harness.socket.closed();

    expect(harness.scheduler.cancels()).toBe(1);
    harness.session.close();
    expect(harness.socket.socket.closes).toBe(0);
  });

  it("ignores a flush deadline that runs after the session already ended", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    // The server can close while the flush is in flight, and a deadline that
    // was already queued still runs. Closing the socket a second time would
    // be a call on a connection that is gone.
    harness.socket.closed();
    harness.scheduler.fire();

    expect(harness.socket.socket.closes).toBe(0);
  });

  it("tolerates a server close with no flush in flight", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.closed();

    expect(harness.scheduler.cancels()).toBe(0);
    harness.session.push(new Uint8Array([1, 2]));
    expect(harness.audio()).toEqual([]);
  });

  it("arms the real timer when no scheduler is injected", () => {
    const socket = socketHarness();
    const session = createElevenLabsTranscriber({
      apiKey: "xi-secret",
      socket: factoryFor(socket).factory,
    }).open({ onTranscript: vi.fn(), onError: vi.fn() });

    socket.started();
    session.close();
    expect(socket.socket.closes).toBe(0);

    // The default deadline is unref'd, and the server close clears it, so no
    // real timer outlives this test.
    socket.closed();
  });
});

describe("ElevenLabs failures", () => {
  const failWith = (frame: unknown): SessionHarness => {
    const harness = openSession();
    harness.socket.started();
    harness.socket.frame(frame);
    return harness;
  };

  it("names a rejected key rather than echoing the provider's detail", () => {
    const harness = failWith({ message_type: "auth_error", error: "invalid xi-api-key xi-secret" });
    expect(harness.reasons).toEqual(["ElevenLabs rejected the API key"]);
    // The provider echoes the key back in its detail; it must not be surfaced.
    expect(harness.reasons[0]).not.toContain("xi-secret");
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("names an exhausted quota", () => {
    expect(failWith({ message_type: "quota_exceeded" }).reasons).toEqual(["ElevenLabs quota exhausted"]);
  });

  it("names a rate limit, however the provider phrased it", () => {
    expect(failWith({ message_type: "rate_limited" }).reasons).toEqual(["ElevenLabs rate limit reached"]);
    expect(failWith({ message_type: "commit_throttled" }).reasons).toEqual(["ElevenLabs rate limit reached"]);
  });

  it("names unaccepted terms, which no retry will fix", () => {
    expect(failWith({ message_type: "unaccepted_terms" }).reasons).toEqual([
      "ElevenLabs terms not accepted for this account",
    ]);
  });

  it("names a session time limit", () => {
    expect(failWith({ message_type: "session_time_limit_exceeded" }).reasons).toEqual([
      "ElevenLabs session time limit reached",
    ]);
  });

  it("passes a frame's error detail through when it is usable", () => {
    expect(failWith({ message_type: "invalid_request", error: "audio_format not supported" }).reasons).toEqual([
      "audio_format not supported",
    ]);
  });

  it("falls back to a generic reason when the detail is absent or unusable", () => {
    expect(failWith({ message_type: "error" }).reasons).toEqual(["Speech-to-text failed"]);
    expect(failWith({ message_type: "input_error", error: "" }).reasons).toEqual(["Speech-to-text failed"]);
    expect(failWith({ message_type: "queue_overflow", error: { code: 500 } }).reasons).toEqual([
      "Speech-to-text failed",
    ]);
  });

  it("recognises every documented error frame, not just a name suffix", () => {
    // A `*_error` suffix heuristic silently misses `error`, `invalid_request`,
    // `quota_exceeded` and the rest, leaving a dead session looking merely
    // quiet while the operator keeps talking into it.
    const types = [
      "error",
      "auth_error",
      "quota_exceeded",
      "commit_throttled",
      "unaccepted_terms",
      "rate_limited",
      "queue_overflow",
      "resource_exhausted",
      "session_time_limit_exceeded",
      "input_error",
      "invalid_request",
      "chunk_size_exceeded",
      "insufficient_audio_activity",
      "transcriber_error",
    ];
    for (const type of types) {
      const harness = failWith({ message_type: type });
      expect(harness.reasons, `${type} must fail the session`).toHaveLength(1);
      expect(harness.socket.socket.closes, `${type} must close the socket`).toBe(1);
    }
  });

  it("describes a transport error generically so the key cannot reach a log", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.error();

    expect(harness.reasons).toEqual(["Speech-to-text connection failed"]);
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("reports a failure once even when several arrive", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "auth_error" });
    harness.socket.error();
    harness.socket.frame({ message_type: "quota_exceeded" });

    expect(harness.reasons).toHaveLength(1);
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("ignores an error frame that arrives after the server closed", () => {
    const harness = openSession();
    harness.socket.started();
    harness.socket.closed();

    harness.socket.frame({ message_type: "auth_error" });

    expect(harness.reasons).toEqual([]);
  });

  it("cancels an in-flight flush when the session fails", () => {
    const harness = openSession();
    harness.socket.started();
    harness.session.close();

    harness.socket.error();

    expect(harness.reasons).toEqual(["Speech-to-text connection failed"]);
    expect(harness.scheduler.cancels()).toBe(1);
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("does not send a commit frame when the failure handler closes the session", () => {
    // This is exactly how the voice session is wired: its onError calls
    // stopCapture(), which closes the transcriber session synchronously. If
    // the session is not sealed before the handler runs, that reentrant close
    // transmits a commit flush on a connection that has just failed.
    let session: TranscriberSession | null = null;
    const harness = openSession({}, () => session?.close());
    session = harness.session;

    harness.socket.started();
    harness.session.push(new Uint8Array([1, 2]));
    harness.socket.frame({ message_type: "auth_error" });

    expect(harness.audio()).toEqual([
      { message_type: "input_audio_chunk", audio_base_64: "1-2", commit: false, sample_rate: 16_000 },
    ]);
    expect(harness.reasons).toEqual(["ElevenLabs rejected the API key"]);
    expect(harness.socket.socket.closes).toBe(1);
  });

  it("stops sending audio after a failure", () => {
    const harness = openSession();
    harness.socket.started();

    harness.socket.frame({ message_type: "auth_error" });
    harness.session.push(new Uint8Array([1, 2]));

    expect(harness.audio()).toEqual([]);
  });
});
