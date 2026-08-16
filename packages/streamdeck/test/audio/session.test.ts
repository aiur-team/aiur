import { describe, expect, it, vi } from "vitest";
import { createVoiceSession, type VoiceSessionOptions } from "../../src/audio/session.js";
import { TARGET_FRAME_BYTES } from "../../src/audio/aggregate.js";
import { FLOOR_DBFS } from "../../src/audio/pcm.js";
import type { Capture, CaptureOptions } from "../../src/audio/capture.js";
import type { SpawnedProcess, SystemPort } from "../../src/audio/system.js";
import type { Transcriber, TranscriberHandlers, TranscriptEvent } from "../../src/audio/stt.js";

/** Encodes signed 16-bit values little-endian, the layout capture emits. */
const s16le = (values: readonly number[]): Uint8Array => {
  const bytes = new Uint8Array(values.length * 2);
  values.forEach((value, index) => {
    const unsigned = value < 0 ? value + 65_536 : value;
    bytes[index * 2] = unsigned & 0xff;
    bytes[index * 2 + 1] = (unsigned >> 8) & 0xff;
  });
  return bytes;
};

/** A `SystemPort` that must never be reached when the capture seam is injected. */
const inertSystem: SystemPort = {
  run: () => Promise.reject(new Error("session must not run a command")),
  spawn: () => {
    throw new Error("session must not spawn");
  },
};

interface CaptureHarness {
  readonly seam: NonNullable<VoiceSessionOptions["capture"]>;
  readonly starts: CaptureOptions[];
  readonly stops: () => number;
  chunk(pcm: Uint8Array): void;
  failCapture(reason: string): void;
}

const captureHarness = (): CaptureHarness => {
  const starts: CaptureOptions[] = [];
  let handlers: { onChunk(pcm: Uint8Array): void; onError(reason: string): void } | null = null;
  let stops = 0;
  const capture: Capture = {
    stop: () => {
      stops += 1;
    },
  };
  return {
    starts,
    stops: () => stops,
    seam: (options, given) => {
      starts.push(options);
      handlers = given;
      return capture;
    },
    chunk: (pcm) => handlers?.onChunk(pcm),
    failCapture: (reason) => handlers?.onError(reason),
  };
};

interface TranscriberHarness {
  readonly transcriber: Transcriber;
  readonly open: ReturnType<typeof vi.fn>;
  /** Frames the transcriber received, after the aggregator re-grouped them. */
  readonly pushed: Uint8Array[];
  /** `push`/`close` in the order they happened, for ordering assertions. */
  readonly log: string[];
  readonly closes: () => number;
  transcript(event: TranscriptEvent): void;
  failTranscription(reason: string): void;
}

const transcriberHarness = (): TranscriberHarness => {
  const pushed: Uint8Array[] = [];
  const log: string[] = [];
  let handlers: TranscriberHandlers | null = null;
  let closes = 0;
  const open = vi.fn((given: TranscriberHandlers) => {
    handlers = given;
    return {
      push: (pcm: Uint8Array) => {
        pushed.push(pcm);
        log.push(`push:${pcm.length}`);
      },
      close: () => {
        closes += 1;
        log.push("close");
      },
    };
  });
  return {
    open,
    pushed,
    log,
    closes: () => closes,
    transcriber: { available: true, unavailableReason: null, open },
    transcript: (event) => handlers?.onTranscript(event),
    failTranscription: (reason) => handlers?.onError(reason),
  };
};

/** One capture chunk of `samples` identical s16le samples. */
const tone = (samples: number, value = 16_384): Uint8Array => s16le(new Array<number>(samples).fill(value));

const baseOptions = (
  overrides: Partial<VoiceSessionOptions> = {},
): VoiceSessionOptions => ({
  system: inertSystem,
  transcriber: transcriberHarness().transcriber,
  deviceId: null,
  waveformWidth: 4,
  onUpdate: vi.fn(),
  onError: vi.fn(),
  ...overrides,
});

describe("voice session lifecycle", () => {
  it("is idle before the key is held", () => {
    const session = createVoiceSession(baseOptions());
    expect(session.holding).toBe(false);
    expect(session.level()).toEqual({ rms: 0, peak: 0, dbfs: FLOOR_DBFS, fill: 0 });
    expect(session.waveform()).toHaveLength(4);
    expect(session.text()).toBe("");
    expect(session.hasMessage()).toBe(false);
  });

  it("opens capture and a transcription when the key goes down", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, deviceId: "alsa_input.yeti" }),
    );

    session.hold();

    expect(session.holding).toBe(true);
    expect(capture.starts).toHaveLength(1);
    expect(capture.starts[0]?.deviceId).toBe("alsa_input.yeti");
    expect(capture.starts[0]?.system).toBe(inertSystem);
    expect(capture.starts[0]?.format).toEqual({ sampleRate: 16_000, channels: 1, bitDepth: 16 });
    expect(stt.open).toHaveBeenCalledOnce();
  });

  it("records at a custom format when one is configured", () => {
    const capture = captureHarness();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, format: { sampleRate: 48_000, channels: 2, bitDepth: 16 } }),
    );
    session.hold();
    expect(capture.starts[0]?.format).toEqual({ sampleRate: 48_000, channels: 2, bitDepth: 16 });
  });

  it("ignores a repeated key-down so two recorders cannot run at once", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    session.hold();

    expect(capture.starts).toHaveLength(1);
    expect(stt.open).toHaveBeenCalledOnce();
  });

  it("uses the real recorder when no capture seam is injected", () => {
    const process: SpawnedProcess = { onData: vi.fn(), onExit: vi.fn(), kill: vi.fn() };
    const spawn = vi.fn(() => process);
    const session = createVoiceSession(
      baseOptions({ system: { run: () => Promise.reject(new Error("no")), spawn }, deviceId: "alsa_input.yeti" }),
    );

    session.hold();

    expect(spawn).toHaveBeenCalledWith("parec", expect.arrayContaining(["--device=alsa_input.yeti"]));
    session.dispose();
    expect(process.kill).toHaveBeenCalledOnce();
  });

  it("ignores a release that was never preceded by a hold", () => {
    const capture = captureHarness();
    const onUpdate = vi.fn();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, onUpdate }));

    session.release();

    expect(capture.stops()).toBe(0);
    expect(onUpdate).not.toHaveBeenCalled();
  });

  it("stops capture and the transcription on release", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onUpdate = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onUpdate }),
    );

    session.hold();
    session.release();
    session.release();

    expect(session.holding).toBe(false);
    expect(capture.stops()).toBe(1);
    expect(stt.closes()).toBe(1);
    expect(onUpdate).toHaveBeenCalledOnce();
  });

  it("resets the meter on release so a stale level is not left on screen", () => {
    const capture = captureHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam }));

    session.hold();
    capture.chunk(s16le([16_384, -16_384]));
    expect(session.level().rms).toBeGreaterThan(0);

    session.release();
    expect(session.level()).toEqual({ rms: 0, peak: 0, dbfs: FLOOR_DBFS, fill: 0 });
  });

  it("releases capture and the provider connection on dispose", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    session.dispose();

    expect(capture.stops()).toBe(1);
    expect(stt.closes()).toBe(1);
    expect(session.holding).toBe(false);
  });

  it("disposes safely when nothing was ever held", () => {
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: captureHarness().seam, transcriber: stt.transcriber }));
    expect(() => session.dispose()).not.toThrow();
    expect(stt.closes()).toBe(0);
  });

  it("clears the waveform at the start of each hold", () => {
    const capture = captureHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, waveformWidth: 2 }));

    session.hold();
    // One column condenses sampleRate/20 samples, so a short burst leaves the
    // reduction mid-column; the next hold must not inherit it.
    capture.chunk(s16le(new Array<number>(800).fill(16_384)));
    expect(session.waveform()[1]).toEqual({ min: 0.5, max: 0.5 });

    session.release();
    session.hold();
    expect(session.waveform()).toEqual([
      { min: 0, max: 0 },
      { min: 0, max: 0 },
    ]);
  });
});

describe("voice session audio flow", () => {
  it("meters every small chunk the moment it lands", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onUpdate = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onUpdate, waveformWidth: 2 }),
    );

    session.hold();
    // 800 samples is 1 600 bytes — half a transcription frame, but a whole
    // waveform column. The meters must not wait for the transcriber's cadence.
    capture.chunk(tone(800));

    expect(session.level().rms).toBeCloseTo(0.5, 6);
    expect(session.level().peak).toBeCloseTo(0.5, 6);
    expect(session.waveform()[1]).toEqual({ min: 0.5, max: 0.5 });
    expect(onUpdate).toHaveBeenCalledOnce();
    expect(stt.pushed).toEqual([]);
  });

  it("re-groups small capture chunks into one transcription frame", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    capture.chunk(tone(800, 16_384));
    capture.chunk(tone(800, -16_384));

    // Two 1 600-byte chunks make exactly one 3 200-byte frame; sending them
    // separately would triple the websocket overhead for no benefit.
    expect(stt.pushed).toHaveLength(1);
    expect(stt.pushed[0]?.length).toBe(TARGET_FRAME_BYTES);
    // Order is preserved across the join: the second chunk's bytes follow the
    // first's, otherwise the audio is reassembled as noise.
    expect(Array.from((stt.pushed[0] as Uint8Array).slice(0, 2))).toEqual([0x00, 0x40]);
    expect(Array.from((stt.pushed[0] as Uint8Array).slice(1_600, 1_602))).toEqual([0x00, 0xc0]);
  });

  it("starts each hold with an empty frame buffer", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    capture.chunk(tone(400));
    session.release();
    stt.pushed.length = 0;

    session.hold();
    capture.chunk(tone(400));

    // The previous hold's tail was already flushed; it must not be prepended
    // to the next utterance.
    expect(stt.pushed).toEqual([]);
  });

  it("flushes the tail of an utterance before closing the socket", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    capture.chunk(tone(400));
    session.release();

    // The tail of an utterance is almost always a partial frame; closing first
    // would clip the last word.
    expect(stt.log).toEqual(["push:800", "close"]);
  });

  it("flushes the tail on dispose as well as on release", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    capture.chunk(tone(100));
    session.dispose();

    expect(stt.log).toEqual(["push:200", "close"]);
  });

  it("closes without a stray empty frame when nothing was buffered", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    session.release();

    expect(stt.log).toEqual(["close"]);
  });

  it("shows the live partial and keeps only settled text for sending", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onUpdate = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onUpdate }),
    );

    session.hold();
    stt.transcript({ kind: "partial", text: "run the tes" });
    expect(session.text()).toBe("run the tes");
    expect(session.hasMessage()).toBe(false);

    stt.transcript({ kind: "final", text: "run the tests" });
    expect(session.text()).toBe("run the tests");
    expect(session.message()).toBe("run the tests");
    expect(session.hasMessage()).toBe(true);
    expect(onUpdate).toHaveBeenCalledTimes(2);
  });

  it("keeps settled text across holds and drops the unfinished partial", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ capture: capture.seam, transcriber: stt.transcriber }));

    session.hold();
    stt.transcript({ kind: "final", text: "run the tests" });
    stt.transcript({ kind: "partial", text: "and then some" });
    session.release();

    expect(session.text()).toBe("run the tests");

    session.hold();
    stt.transcript({ kind: "final", text: "then open a pull request" });
    expect(session.message()).toBe("run the tests then open a pull request");
  });

  it("discards the buffer on clear and repaints", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onUpdate = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onUpdate }),
    );

    session.hold();
    stt.transcript({ kind: "final", text: "run the tests" });
    onUpdate.mockClear();

    session.clear();

    expect(session.text()).toBe("");
    expect(session.hasMessage()).toBe(false);
    expect(onUpdate).toHaveBeenCalledOnce();
  });
});

describe("voice session without transcription", () => {
  const unavailable: Transcriber = {
    available: false,
    unavailableReason: "No ElevenLabs API key - transcription is off",
    open: vi.fn(),
  };

  it("exposes why transcription is off", () => {
    const session = createVoiceSession(baseOptions({ transcriber: unavailable, capture: captureHarness().seam }));
    expect(session.transcriptionAvailable).toBe(false);
    expect(session.unavailableReason).toBe("No ElevenLabs API key - transcription is off");
  });

  it("reports transcription as available when it is", () => {
    const stt = transcriberHarness();
    const session = createVoiceSession(baseOptions({ transcriber: stt.transcriber, capture: captureHarness().seam }));
    expect(session.transcriptionAvailable).toBe(true);
    expect(session.unavailableReason).toBeNull();
  });

  it("still captures and meters, and never opens a socket", () => {
    const capture = captureHarness();
    const open = vi.fn();
    const session = createVoiceSession(
      baseOptions({
        capture: capture.seam,
        transcriber: { available: false, unavailableReason: "no key", open },
        waveformWidth: 2,
      }),
    );

    session.hold();
    capture.chunk(s16le(new Array<number>(800).fill(16_384)));

    // Without a key there is nowhere for audio to go, so no connection is made
    // and nothing leaves the machine — but the meters still run.
    expect(open).not.toHaveBeenCalled();
    expect(session.holding).toBe(true);
    expect(session.level().rms).toBeCloseTo(0.5, 6);
    expect(session.waveform()[1]).toEqual({ min: 0.5, max: 0.5 });
    expect(session.text()).toBe("");

    session.release();
    expect(session.holding).toBe(false);
  });
});

describe("voice session failures", () => {
  it("reports a capture failure and stops the session", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onError = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onError }),
    );

    session.hold();
    capture.failCapture("Microphone capture failed (exit 1)");

    expect(onError).toHaveBeenCalledWith("Microphone capture failed (exit 1)");
    expect(session.holding).toBe(false);
    expect(capture.stops()).toBe(1);
    expect(stt.closes()).toBe(1);
  });

  it("reports a transcription failure and stops capture with it", () => {
    const capture = captureHarness();
    const stt = transcriberHarness();
    const onError = vi.fn();
    const session = createVoiceSession(
      baseOptions({ capture: capture.seam, transcriber: stt.transcriber, onError }),
    );

    session.hold();
    stt.transcript({ kind: "final", text: "run the tests" });
    stt.failTranscription("ElevenLabs quota exhausted");

    expect(onError).toHaveBeenCalledWith("ElevenLabs quota exhausted");
    expect(session.holding).toBe(false);
    expect(capture.stops()).toBe(1);
    // A dead mic must not silently swallow what was already said.
    expect(session.message()).toBe("run the tests");
  });
});
