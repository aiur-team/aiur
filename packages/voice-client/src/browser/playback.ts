import { VoiceClientError, type AudioPlaybackAdapter, type PlaybackStop } from "../types.js";
import type { AudioContextConstructor, AudioNodeLike, Pcm16AudioChunk } from "./types.js";

interface AudioBufferLike {
  readonly duration: number;
  copyToChannel(samples: Float32Array, channel: number): void;
}

interface BufferSourceLike extends AudioNodeLike {
  buffer: AudioBufferLike | null;
  onended: (() => void) | null;
  start(time: number): void;
  stop(): void;
}

export interface PlaybackAudioContextLike {
  readonly currentTime: number;
  readonly destination: AudioNodeLike;
  createBuffer(channels: number, length: number, sampleRate: number): AudioBufferLike;
  createBufferSource(): BufferSourceLike;
  close(): Promise<void>;
}

export interface BrowserPlaybackDependencies {
  readonly AudioContext: AudioContextConstructor<PlaybackAudioContextLike>;
}

export interface BrowserAudioPlaybackOptions {
  readonly dependencies?: BrowserPlaybackDependencies;
}

interface ScheduledSource {
  readonly source: BufferSourceLike;
  readonly startTime: number;
  readonly offsetMs: number;
  readonly durationMs: number;
}

const platformDependencies = (): BrowserPlaybackDependencies | undefined => {
  const platform = globalThis as typeof globalThis & {
    readonly AudioContext?: AudioContextConstructor<PlaybackAudioContextLike>;
    readonly webkitAudioContext?: AudioContextConstructor<PlaybackAudioContextLike>;
  };
  const AudioContext = platform.AudioContext ?? platform.webkitAudioContext;
  return AudioContext ? { AudioContext } : undefined;
};

export const createBrowserAudioPlayback = (
  options: BrowserAudioPlaybackOptions = {},
): AudioPlaybackAdapter<Pcm16AudioChunk> => {
  const dependencies = options.dependencies ?? platformDependencies();
  if (!dependencies) {
    throw new VoiceClientError("audio_unavailable", "Browser Web Audio playback support is required");
  }
  try {
    return new BrowserAudioPlayback(new dependencies.AudioContext());
  } catch {
    throw new VoiceClientError("playback_failed", "Audio playback could not be started");
  }
};

class BrowserAudioPlayback implements AudioPlaybackAdapter<Pcm16AudioChunk> {
  readonly #scheduled = new Set<ScheduledSource>();
  #closed = false;
  #completedMs = 0;
  #nextStart = 0;
  #queuedMs = 0;

  constructor(private readonly context: PlaybackAudioContextLike) {}

  enqueue(chunk: Pcm16AudioChunk): void {
    if (this.#closed) throw new VoiceClientError("playback_failed", "Audio playback is closed");
    validateChunk(chunk);
    if (chunk.samples.length === 0) return;
    try {
      this.queue(chunk);
    } catch {
      this.interrupt();
      throw new VoiceClientError("playback_failed", "Audio playback could not be queued");
    }
  }

  interrupt(): PlaybackStop {
    if (this.#closed) return { playedUntilMs: 0 };
    let playedUntilMs = this.#completedMs;
    for (const scheduled of this.#scheduled) {
      playedUntilMs = Math.max(playedUntilMs, playedOffset(scheduled, this.context.currentTime));
      stopSource(scheduled.source);
    }
    this.resetQueue();
    return { playedUntilMs: Math.round(playedUntilMs) };
  }

  async close(): Promise<void> {
    if (this.#closed) return;
    for (const scheduled of this.#scheduled) stopSource(scheduled.source);
    this.resetQueue();
    this.#closed = true;
    try {
      await this.context.close();
    } catch {
      throw new VoiceClientError("playback_failed", "Audio playback could not be closed");
    }
  }

  private queue(chunk: Pcm16AudioChunk): void {
    const buffer = this.createBuffer(chunk);
    const source = this.context.createBufferSource();
    const startTime = Math.max(this.context.currentTime, this.#nextStart);
    const scheduled = this.schedule(source, buffer, startTime);
    source.onended = () => this.complete(scheduled);
    source.connect(this.context.destination);
    source.start(startTime);
  }

  private createBuffer(chunk: Pcm16AudioChunk): AudioBufferLike {
    const buffer = this.context.createBuffer(1, chunk.samples.length, chunk.sampleRateHz);
    buffer.copyToChannel(Float32Array.from(chunk.samples, (sample) => sample / 32_768), 0);
    return buffer;
  }

  private schedule(source: BufferSourceLike, buffer: AudioBufferLike, startTime: number): ScheduledSource {
    source.buffer = buffer;
    const durationMs = buffer.duration * 1_000;
    const scheduled = { source, startTime, offsetMs: this.#queuedMs, durationMs };
    this.#scheduled.add(scheduled);
    this.#queuedMs += durationMs;
    this.#nextStart = startTime + buffer.duration;
    return scheduled;
  }

  private complete(scheduled: ScheduledSource): void {
    this.#completedMs = Math.max(this.#completedMs, scheduled.offsetMs + scheduled.durationMs);
    this.#scheduled.delete(scheduled);
    safeDisconnect(scheduled.source);
  }

  private resetQueue(): void {
    this.#scheduled.clear();
    this.#completedMs = 0;
    this.#queuedMs = 0;
    this.#nextStart = this.context.currentTime;
  }
}

const validateChunk = (chunk: Pcm16AudioChunk): void => {
  if (!Number.isFinite(chunk.sampleRateHz) || chunk.sampleRateHz <= 0) {
    throw new VoiceClientError("playback_failed", "Audio sample rate must be positive");
  }
};

const playedOffset = (scheduled: ScheduledSource, now: number): number => {
  if (now <= scheduled.startTime) return 0;
  const elapsedMs = Math.max(0, (now - scheduled.startTime) * 1_000);
  return scheduled.offsetMs + Math.min(elapsedMs, scheduled.durationMs);
};

const stopSource = (source: BufferSourceLike): void => {
  source.onended = null;
  try {
    source.stop();
  } catch {
    // Already-ended sources need no further work.
  }
  safeDisconnect(source);
};

const safeDisconnect = (source: BufferSourceLike): void => {
  try {
    source.disconnect();
  } catch {
    // The browser may already have disconnected an ended source.
  }
};
