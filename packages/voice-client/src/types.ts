export type VoiceConnectionState = "connecting" | "open" | "closing" | "failed" | "closed";

export type VoiceClientErrorCode =
  | "audio_unavailable"
  | "capture_failed"
  | "connection_failed"
  | "connection_not_open"
  | "playback_failed"
  | "protocol_error"
  | "transport_error"
  | "websocket_unavailable";

export class VoiceClientError extends Error {
  readonly code: VoiceClientErrorCode;

  constructor(code: VoiceClientErrorCode, message: string) {
    super(message);
    this.name = "VoiceClientError";
    this.code = code;
  }
}

export interface VoiceSocket {
  onopen: (() => void) | null;
  onmessage: ((event: { readonly data: unknown }) => void) | null;
  onerror: ((error: unknown) => void) | null;
  onclose: (() => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

export interface VoiceSocketFactoryOptions {
  readonly endpoint: string;
  readonly token: string;
}

export type VoiceSocketFactory = (options: VoiceSocketFactoryOptions) => VoiceSocket;

export interface WireCodec<OutboundFrame, InboundFrame> {
  encodeOutbound(frame: OutboundFrame): string;
  decodeInbound(data: unknown): InboundFrame;
}

export interface VoiceConnectionEvents<InboundFrame> {
  readonly stateChanged?: (state: VoiceConnectionState) => void;
  readonly frame?: (frame: InboundFrame) => void;
  readonly error?: (error: VoiceClientError) => void;
}

export interface VoiceConnectionOptions<OutboundFrame, InboundFrame> {
  readonly endpoint: string;
  readonly token: string;
  readonly socketFactory: VoiceSocketFactory;
  readonly codec: WireCodec<OutboundFrame, InboundFrame>;
  readonly events?: VoiceConnectionEvents<InboundFrame>;
}

export interface VoiceWireConnection<OutboundFrame> {
  readonly state: VoiceConnectionState;
  send(frame: OutboundFrame): void;
  close(): void;
}

export interface AudioCaptureAdapter<AudioChunk> {
  start(onChunk: (chunk: AudioChunk) => void): Promise<void>;
  stop(): Promise<void>;
}

export interface PlaybackStop {
  readonly playedUntilMs: number;
}

export interface AudioPlaybackAdapter<AudioChunk> {
  enqueue(chunk: AudioChunk): void;
  interrupt(): PlaybackStop;
  close(): Promise<void>;
}
