/**
 * Live-typing emulation for the newest transcript row.
 *
 * The daemon delivers a message as one completed string — the provider stream
 * is reassembled server-side long before it reaches this process — so there is
 * no character stream to forward. The operator asked for the *appearance* of
 * the agent typing and explicitly accepted an emulation, so this reveals a
 * newly-arrived body a few characters at a time and the surface repaints as it
 * goes.
 *
 * Three rules keep it honest rather than decorative:
 *
 * - **Only the newest row, only while live.** Scrolled back into a past event,
 *   nothing animates: replaying old text as if it were being typed now would
 *   misrepresent when it happened.
 * - **Never on the first snapshot.** Entering logs shows the transcript as it
 *   already is. Typing out history the moment the surface opens would claim the
 *   agent said all of it just now.
 * - **An extension resumes, it does not restart.** Providers often re-send a
 *   growing body for the same row; treating that as a new message would rewind
 *   the reveal and stutter.
 */

import type { TranscriptRow } from "../channel.js";

/** Characters revealed per tick. At the 40ms host tick this reads as fast typing. */
export const TYPING_CHARS_PER_TICK = 6;

export interface Typewriter {
  /** Records the latest history. `live` is false whenever the operator has scrolled away. */
  observe(rows: readonly TranscriptRow[], live: boolean): void;
  /** Advances the reveal. Returns true while there is still text to reveal. */
  tick(): boolean;
  animating(): boolean;
  /** The history with the animated row clipped to what has been revealed. */
  render(rows: readonly TranscriptRow[]): readonly TranscriptRow[];
  /**
   * Forgets everything, including that a first snapshot was ever seen.
   *
   * Called when the surface switches to a different agent: `index` and `target`
   * describe a row in *that* agent's transcript, and the never-type-out-history
   * rule has to apply again to the new one.
   */
  forget(): void;
}

export const createTypewriter = (charsPerTick: number = TYPING_CHARS_PER_TICK): Typewriter => {
  /** Whether a first snapshot has been adopted. */
  let seeded = false;
  /** Row currently being animated, or the row last adopted in full. */
  let index = -1;
  /** That row's complete body — what the reveal is heading towards. */
  let target = "";
  let revealed = 0;
  /**
   * Separate from `index` on purpose. A finished reveal must remember *what* it
   * finished, or the next snapshot carrying the same unchanged body would look
   * like a brand-new message and the row would type itself out forever.
   */
  let active = false;

  const adopt = (at: number, body: string): void => {
    index = at;
    target = body;
    revealed = body.length;
    active = false;
  };

  return {
    observe: (rows, live) => {
      const last = rows.length - 1;
      const row = last >= 0 ? rows[last] : undefined;
      if (row === undefined || row.kind !== "message") {
        adopt(last, "");
        seeded = true;
        return;
      }
      if (!seeded) {
        seeded = true;
        adopt(last, row.body);
        return;
      }
      if (!live) {
        adopt(last, row.body);
        return;
      }
      if (index === last && row.body === target) return;
      if (index === last && row.body.startsWith(target)) {
        // The provider re-sent a growing body for the same row. Resume from
        // where the reveal already is rather than rewinding it.
        revealed = Math.min(revealed, target.length);
        target = row.body;
        active = true;
        return;
      }
      index = last;
      target = row.body;
      revealed = 0;
      active = true;
    },
    tick: () => {
      if (!active) return false;
      revealed += charsPerTick;
      if (revealed >= target.length) {
        revealed = target.length;
        active = false;
        return false;
      }
      return true;
    },
    animating: () => active,
    forget: () => {
      seeded = false;
      adopt(-1, "");
    },
    render: (rows) => {
      if (!active) return rows;
      const row = rows[index];
      if (row === undefined || row.kind !== "message") return rows;
      const clipped = rows.slice();
      clipped[index] = { ...row, body: target.slice(0, revealed) };
      return clipped;
    },
  };
};
