/**
 * Provider-agnostic text-to-speech contract.
 *
 * Nothing below names a vendor and nothing imports from the Stream Deck
 * sidecar. This is the output mirror of `stt.ts`: consumers hold a
 * `TTSProvider` and never know which vendor synthesizes the audio. Like the
 * capture seam, the contract is what lets a future package take
 * `src/audio/**` wholesale — the sidecar keeps only the call that picks a
 * provider.
 */

/** One synthesis request. A turn carries a single `requestId`. */
export interface TTSInput {
  /** Correlates a request across logs; the turn loop passes one. */
  readonly requestId: string;
  /** The text to speak. */
  readonly text: string;
  /** A provider voice identifier. */
  readonly voiceId: string;
  /** Output encoding: "pcm_44100" for raw PCM, or an mp3/ogg format. */
  readonly format?: string;
  /** Provider model override. */
  readonly model?: string;
}

/**
 * A provider that turns text into a stream of encoded audio bytes.
 *
 * The caller owns cancellation: abandoning the async iterator ends synthesis.
 * Providers must not retry internally or buffer the whole utterance.
 */
export interface TTSProvider {
  /** False when TTS is not configured; the caller degrades on this. */
  readonly available: boolean;
  /**
   * Operator-facing explanation when `available` is false. Always non-null in
   * that case so the deck can say *why* rather than failing silently.
   */
  readonly unavailableReason: string | null;
  /** Synthesizes `input.text`, yielding encoded audio chunks. Throws on failure. */
  synthesizeStream(input: TTSInput): AsyncIterable<Uint8Array>;
}

/**
 * The provider used when no API key is configured.
 *
 * It never reaches the network, so no request leaves the machine. The reason
 * is carried where the caller can print it rather than a silent no-op.
 */
export function createUnavailableTTSProvider(reason: string): TTSProvider {
  return {
    available: false,
    unavailableReason: reason,
    synthesizeStream(): AsyncIterable<Uint8Array> {
      return {
        [Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
          return {
            async next(): Promise<IteratorResult<Uint8Array>> {
              throw new Error(reason);
            },
          };
        },
      };
    },
  };
}
