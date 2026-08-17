/**
 * The audio-output port for the voice stack.
 *
 * Capture expresses the host as a two-function `SystemPort` (`system.ts`) and
 * a websocket factory (`stt.ts`). Playback is the mirror image: a single
 * byte-sink port the core streams encoded audio into. Core modules take the
 * port as an argument and never name the playback binary themselves — the
 * same rule that keeps `src/audio/**` independently testable and extractable.
 */

/** A sink for encoded audio bytes heading to an output device. */
export interface PlaybackPort {
  /**
   * Writes one chunk of encoded audio. Resolves when the chunk is accepted
   * (including across backpressure). Safe to call after `close`; it is a
   * no-op then.
   */
  write(chunk: Uint8Array): Promise<void> | void;
  /** Flushes and releases the device. Safe to call twice. */
  close(): Promise<void> | void;
}

/**
 * Plays an encoded-audio stream through a playback port.
 *
 * The port is closed exactly once — whether the stream ends, throws, or the
 * caller stops awaiting — so a device is never left held. Callers that stop
 * caring simply stop awaiting; release is guaranteed by `finally`.
 */
export async function playEncodedAudio(
  port: PlaybackPort,
  audio: AsyncIterable<Uint8Array>,
): Promise<void> {
  try {
    for await (const chunk of audio) {
      await port.write(chunk);
    }
  } finally {
    await port.close();
  }
}
