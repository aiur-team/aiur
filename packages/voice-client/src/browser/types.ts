export interface Pcm16AudioChunk {
  readonly samples: Int16Array;
  readonly sampleRateHz: number;
}

export interface AudioNodeLike {
  connect(node: AudioNodeLike): unknown;
  disconnect(): void;
}

export interface AudioContextConstructor<Context> {
  new (): Context;
}
