/**
 * Re-groups capture chunks for the transcriber.
 *
 * Capture runs at a 20 ms latency because anything larger makes `parec`
 * swallow the first word, but 20 ms of 16 kHz mono is only 640 bytes and the
 * realtime transcription endpoint expects frames in the low kilobytes. Sending
 * 640-byte frames works but triples the websocket overhead for no benefit.
 *
 * So the meters consume every small chunk as it lands — that is what keeps the
 * waveform smooth — while the transcriber sees them re-grouped into frames of
 * roughly 100 ms. The split is deliberate: the two consumers want different
 * cadences from the same stream.
 *
 * Byte-counting only, no timer: a test drives this with fixed arrays.
 */

/** Bytes per frame handed onward. 100 ms of 16 kHz mono s16le is 3 200 bytes. */
export const TARGET_FRAME_BYTES = 3_200;

export interface ChunkAggregator {
  /** Folds a chunk in, emitting zero or more full frames. */
  push(chunk: Uint8Array): void;
  /**
   * Emits whatever is buffered, however short.
   *
   * Called when the operator releases the key: the tail of an utterance is
   * usually a partial frame, and dropping it would clip the last word.
   */
  flush(): void;
  /** Discards buffered audio without emitting it. */
  reset(): void;
}

export function createChunkAggregator(
  onFrame: (frame: Uint8Array) => void,
  targetBytes: number = TARGET_FRAME_BYTES,
): ChunkAggregator {
  if (targetBytes <= 0) throw new Error("aggregator targetBytes must be positive");

  let buffered: Uint8Array[] = [];
  let bufferedBytes = 0;

  const drain = (): void => {
    const frame = new Uint8Array(bufferedBytes);
    let offset = 0;
    for (const part of buffered) {
      frame.set(part, offset);
      offset += part.length;
    }
    buffered = [];
    bufferedBytes = 0;
    onFrame(frame);
  };

  return {
    push(chunk: Uint8Array): void {
      if (chunk.length === 0) return;
      buffered.push(chunk);
      bufferedBytes += chunk.length;
      // A single oversized chunk still emits exactly one frame; the endpoint
      // has no upper bound we are near, so splitting it would gain nothing.
      if (bufferedBytes >= targetBytes) drain();
    },
    flush(): void {
      if (bufferedBytes === 0) return;
      drain();
    },
    reset(): void {
      buffered = [];
      bufferedBytes = 0;
    },
  };
}
