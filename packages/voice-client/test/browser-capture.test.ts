import assert from "node:assert/strict";
import test from "node:test";

import {
  createBrowserAudioCapture,
  type BrowserCaptureDependencies,
  type CaptureAudioContextLike,
  type Pcm16AudioChunk,
} from "../src/browser.js";
import type { VoiceClientError } from "../src/index.js";

class FakeNode {
  disconnects = 0;
  readonly connections: FakeNode[] = [];

  connect(node: FakeNode): void {
    this.connections.push(node);
  }

  disconnect(): void {
    this.disconnects += 1;
  }
}

class FakeProcessor extends FakeNode {
  onaudioprocess: ((event: { inputBuffer: { getChannelData(channel: number): Float32Array } }) => void) | null = null;

  emit(samples: readonly number[]): void {
    this.onaudioprocess?.({ inputBuffer: { getChannelData: () => Float32Array.from(samples) } });
  }
}

class FakeStream {
  stops = 0;
  getTracks(): Array<{ stop: () => void }> {
    return [{ stop: () => { this.stops += 1; } }];
  }
}

class FakeCaptureContext implements CaptureAudioContextLike {
  static latest: FakeCaptureContext | undefined;
  readonly sampleRate = 8;
  readonly destination = new FakeNode();
  readonly source = new FakeNode();
  readonly processor = new FakeProcessor();
  readonly silence = Object.assign(new FakeNode(), { gain: { value: 1 } });
  closes = 0;

  constructor() {
    FakeCaptureContext.latest = this;
  }

  createMediaStreamSource(): FakeNode {
    return this.source;
  }

  createScriptProcessor(): FakeProcessor {
    return this.processor;
  }

  createGain(): typeof this.silence {
    return this.silence;
  }

  async close(): Promise<void> {
    this.closes += 1;
  }
}

const dependencies = (stream: FakeStream): BrowserCaptureDependencies => ({
  getUserMedia: async () => stream,
  AudioContext: FakeCaptureContext,
});

test("browser capture emits ordered PCM chunks and releases every resource", async () => {
  const stream = new FakeStream();
  const chunks: Pcm16AudioChunk[] = [];
  const capture = createBrowserAudioCapture({ targetSampleRateHz: 4, bufferSize: 8, dependencies: dependencies(stream) });

  await capture.start((chunk) => chunks.push(chunk));
  const context = FakeCaptureContext.latest!;
  context.processor.emit([-1, -0.5, 0, 0.5, 1]);
  context.processor.emit([0.75, 0.5, 0.25, 0]);

  assert.deepEqual(chunks.map(({ samples, sampleRateHz }) => ({ samples: [...samples], sampleRateHz })), [
    { samples: [-32_768, 0], sampleRateHz: 4 },
    { samples: [32_767, 16_384], sampleRateHz: 4 },
  ]);
  assert.equal(context.silence.gain.value, 0);

  await capture.stop();
  await capture.stop();
  assert.equal(stream.stops, 1);
  assert.equal(context.closes, 1);
  assert.deepEqual([context.source.disconnects, context.processor.disconnects, context.silence.disconnects], [1, 1, 1]);
});

test("microphone failures are reported without leaking platform details", async () => {
  const capture = createBrowserAudioCapture({
    dependencies: {
      getUserMedia: async () => { throw new Error("permission denied for secret-device-name"); },
      AudioContext: FakeCaptureContext,
    },
  });

  await assert.rejects(capture.start(() => undefined), (error: VoiceClientError) => {
    assert.equal(error.code, "capture_failed");
    assert.doesNotMatch(error.message, /secret-device-name/);
    return true;
  });
});
