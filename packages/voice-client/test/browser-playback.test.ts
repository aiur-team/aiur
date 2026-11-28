import assert from "node:assert/strict";
import test from "node:test";

import {
  createBrowserAudioPlayback,
  type PlaybackAudioContextLike,
} from "../src/browser.js";
import type { VoiceClientError } from "../src/index.js";

class FakeNode {
  disconnects = 0;
  connect(_node: FakeNode): void {}
  disconnect(): void {
    this.disconnects += 1;
  }
}

class FakeBuffer {
  samples = new Float32Array();
  constructor(readonly duration: number) {}
  copyToChannel(samples: Float32Array): void {
    this.samples = samples;
  }
}

class FakeSource extends FakeNode {
  buffer: FakeBuffer | null = null;
  onended: (() => void) | null = null;
  startTime: number | undefined;
  stops = 0;

  start(time: number): void {
    this.startTime = time;
  }

  stop(): void {
    this.stops += 1;
  }
}

class FakePlaybackContext implements PlaybackAudioContextLike {
  static latest: FakePlaybackContext | undefined;
  currentTime = 0;
  readonly destination = new FakeNode();
  readonly buffers: FakeBuffer[] = [];
  readonly sources: FakeSource[] = [];
  closes = 0;

  constructor() {
    FakePlaybackContext.latest = this;
  }

  createBuffer(_channels: number, length: number, sampleRate: number): FakeBuffer {
    const buffer = new FakeBuffer(length / sampleRate);
    this.buffers.push(buffer);
    return buffer;
  }

  createBufferSource(): FakeSource {
    const source = new FakeSource();
    this.sources.push(source);
    return source;
  }

  async close(): Promise<void> {
    this.closes += 1;
  }
}

test("browser playback queues PCM buffers and reports the audible interruption offset", () => {
  const playback = createBrowserAudioPlayback({ dependencies: { AudioContext: FakePlaybackContext } });
  const context = FakePlaybackContext.latest!;
  const chunk = { samples: Int16Array.from([-32_768, 0, 16_384, 32_767]), sampleRateHz: 4 };

  playback.enqueue(chunk);
  playback.enqueue(chunk);

  assert.deepEqual(context.sources.map(({ startTime }) => startTime), [0, 1]);
  assert.deepEqual([...context.buffers[0]!.samples], [-1, 0, 0.5, 32_767 / 32_768]);

  context.currentTime = 0.25;
  assert.deepEqual(playback.interrupt(), { playedUntilMs: 250 });
  assert.deepEqual(context.sources.map(({ stops }) => stops), [1, 1]);
});

test("completed playback contributes to the interruption offset", () => {
  const playback = createBrowserAudioPlayback({ dependencies: { AudioContext: FakePlaybackContext } });
  const context = FakePlaybackContext.latest!;
  playback.enqueue({ samples: Int16Array.from([0, 0]), sampleRateHz: 2 });
  playback.enqueue({ samples: Int16Array.from([0, 0]), sampleRateHz: 2 });
  context.sources[0]!.onended?.();

  context.currentTime = 1.5;

  assert.deepEqual(playback.interrupt(), { playedUntilMs: 1_500 });
});

test("closing playback is idempotent and rejects later audio", async () => {
  const playback = createBrowserAudioPlayback({ dependencies: { AudioContext: FakePlaybackContext } });
  const context = FakePlaybackContext.latest!;
  playback.enqueue({ samples: Int16Array.from([0]), sampleRateHz: 1 });

  await playback.close();
  await playback.close();

  assert.equal(context.closes, 1);
  assert.throws(
    () => playback.enqueue({ samples: Int16Array.from([0]), sampleRateHz: 1 }),
    (error: VoiceClientError) => error.code === "playback_failed",
  );
});
