/**
 * The accumulating transcript buffer behind the mic key.
 *
 * The operator can hold the mic key several times before sending, and expects
 * to see everything they have said so far. Settled text is therefore appended
 * across holds, while the in-flight partial is kept apart so it can be revised
 * in place and discarded if the utterance never settles.
 *
 * Pure and synchronous: no timers, no I/O.
 */

import type { TranscriptEvent } from "./stt.js";

export interface TranscriptBuffer {
  /** Folds one provider update into the buffer. */
  apply(event: TranscriptEvent): void;
  /** Settled text plus the live partial — what the bottom panel shows. */
  display(): string;
  /** Settled text only — what Send delivers to the agent. */
  committed(): string;
  /** True when there is nothing worth sending. */
  isEmpty(): boolean;
  /** Drops the in-flight partial, keeping settled text. Used when a hold ends. */
  dropPartial(): void;
  /** Discards everything. Backs the Cancel key and follows a successful Send. */
  clear(): void;
}

const joinSpoken = (left: string, right: string): string => {
  if (left === "") return right;
  if (right === "") return left;
  return `${left} ${right}`;
};

export function createTranscriptBuffer(): TranscriptBuffer {
  const settled: string[] = [];
  let partial = "";

  const committed = (): string => settled.join(" ");

  return {
    apply(event: TranscriptEvent): void {
      const text = event.text.trim();
      if (event.kind === "partial") {
        partial = text;
        return;
      }
      // A settled utterance supersedes whatever partial preceded it; keeping
      // both would duplicate every phrase in the panel.
      partial = "";
      if (text !== "") settled.push(text);
    },
    display(): string {
      return joinSpoken(committed(), partial);
    },
    committed,
    isEmpty(): boolean {
      return settled.length === 0;
    },
    dropPartial(): void {
      partial = "";
    },
    clear(): void {
      settled.length = 0;
      partial = "";
    },
  };
}
