import { VoiceClientError, type AudioCaptureAdapter } from "../types.js";
import { Pcm16Downsampler } from "./pcm.js";
import type { AudioContextConstructor, AudioNodeLike, Pcm16AudioChunk } from "./types.js";

interface MediaTrackLike {
  stop(): void;
}

interface MediaStreamLike {
  getTracks(): readonly MediaTrackLike[];
}

interface InputBufferLike {
  getChannelData(channel: number): Float32Array;
}

interface AudioProcessEventLike {
  readonly inputBuffer: InputBufferLike;
}

interface ScriptProcessorLike extends AudioNodeLike {
  onaudioprocess: ((event: AudioProcessEventLike) => void) | null;
}

interface GainNodeLike extends AudioNodeLike {
  readonly gain: { value: number };
}

export interface CaptureAudioContextLike {
  readonly sampleRate: number;
  readonly destination: AudioNodeLike;
  createMediaStreamSource(stream: MediaStreamLike): AudioNodeLike;
  createScriptProcessor(bufferSize: number, inputChannels: number, outputChannels: number): ScriptProcessorLike;
  createGain(): GainNodeLike;
  close(): Promise<void>;
}

export interface BrowserCaptureDependencies {
  readonly getUserMedia: () => Promise<MediaStreamLike>;
  readonly AudioContext: AudioContextConstructor<CaptureAudioContextLike>;
}

export interface BrowserAudioCaptureOptions {
  readonly targetSampleRateHz?: number;
  readonly bufferSize?: number;
  readonly dependencies?: BrowserCaptureDependencies;
}

const platformDependencies = (): BrowserCaptureDependencies | undefined => {
  const platform = globalThis as typeof globalThis & {
    readonly navigator?: { readonly mediaDevices?: { getUserMedia(options: unknown): Promise<MediaStreamLike> } };
    readonly AudioContext?: AudioContextConstructor<CaptureAudioContextLike>;
    readonly webkitAudioContext?: AudioContextConstructor<CaptureAudioContextLike>;
  };
  const mediaDevices = platform.navigator?.mediaDevices;
  const AudioContext = platform.AudioContext ?? platform.webkitAudioContext;
  if (!mediaDevices || !AudioContext) return undefined;
  return {
    getUserMedia: () => mediaDevices.getUserMedia({ audio: true }),
    AudioContext,
  };
};

export const createBrowserAudioCapture = (
  options: BrowserAudioCaptureOptions = {},
): AudioCaptureAdapter<Pcm16AudioChunk> => new BrowserAudioCapture(
  options.dependencies ?? platformDependencies(),
  options.targetSampleRateHz ?? 16_000,
  options.bufferSize ?? 4_096,
);

class BrowserAudioCapture implements AudioCaptureAdapter<Pcm16AudioChunk> {
  #context: CaptureAudioContextLike | undefined;
  #nodes: AudioNodeLike[] = [];
  #processor: ScriptProcessorLike | undefined;
  #setup: Promise<void> | undefined;
  #stopRequested = false;
  #stream: MediaStreamLike | undefined;

  constructor(
    private readonly dependencies: BrowserCaptureDependencies | undefined,
    private readonly targetSampleRateHz: number,
    private readonly bufferSize: number,
  ) {
    if (targetSampleRateHz <= 0 || bufferSize <= 0) throw new RangeError("Audio rates and buffers must be positive");
  }

  async start(onChunk: (chunk: Pcm16AudioChunk) => void): Promise<void> {
    if (this.#setup) throw new VoiceClientError("capture_failed", "Audio capture has already started");
    if (!this.dependencies) throw unavailable();
    this.#setup = this.setup(onChunk);
    await this.#setup;
  }

  async stop(): Promise<void> {
    this.#stopRequested = true;
    try {
      await this.#setup;
    } catch {
      // start reports its own redacted failure; stop remains safe and idempotent.
    }
    await this.cleanup();
  }

  private async setup(onChunk: (chunk: Pcm16AudioChunk) => void): Promise<void> {
    try {
      this.#stream = await this.dependencies!.getUserMedia();
      if (this.#stopRequested) return;
      this.connectGraph(onChunk);
    } catch {
      await this.cleanup();
      throw new VoiceClientError("capture_failed", "Microphone capture could not be started");
    }
  }

  private connectGraph(onChunk: (chunk: Pcm16AudioChunk) => void): void {
    const context = new this.dependencies!.AudioContext();
    this.#context = context;
    const resampler = new Pcm16Downsampler(context.sampleRate, this.targetSampleRateHz);
    const source = context.createMediaStreamSource(this.#stream!);
    const processor = context.createScriptProcessor(this.bufferSize, 1, 1);
    const silence = context.createGain();
    this.#processor = processor;
    this.#nodes = [source, processor, silence];
    silence.gain.value = 0;
    processor.onaudioprocess = (event) => emitChunk(event, resampler, onChunk);
    source.connect(processor);
    processor.connect(silence);
    silence.connect(context.destination);
  }

  private async cleanup(): Promise<void> {
    this.#processor && (this.#processor.onaudioprocess = null);
    for (const node of this.#nodes) safeDisconnect(node);
    for (const track of this.#stream?.getTracks() ?? []) safeStop(track);
    this.#nodes = [];
    this.#stream = undefined;
    const context = this.#context;
    this.#context = undefined;
    if (context) await safeClose(context);
  }
}

const emitChunk = (
  event: AudioProcessEventLike,
  resampler: Pcm16Downsampler,
  onChunk: (chunk: Pcm16AudioChunk) => void,
): void => {
  const samples = resampler.push(event.inputBuffer.getChannelData(0));
  if (samples.length > 0) onChunk({ samples, sampleRateHz: resampler.targetRateHz });
};

const safeDisconnect = (node: AudioNodeLike): void => {
  try {
    node.disconnect();
  } catch {
    // Browser graph cleanup is best effort after a partial start.
  }
};

const safeStop = (track: MediaTrackLike): void => {
  try {
    track.stop();
  } catch {
    // A browser may already have ended the track.
  }
};

const safeClose = async (context: CaptureAudioContextLike): Promise<void> => {
  try {
    await context.close();
  } catch {
    // A partially-created context may already be closed.
  }
};

const unavailable = (): VoiceClientError => new VoiceClientError(
  "audio_unavailable",
  "Browser microphone and Web Audio support are required",
);
