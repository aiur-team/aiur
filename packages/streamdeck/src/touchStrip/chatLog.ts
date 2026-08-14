/**
 * logs-mode strip view-model: the agent's chat log, and which event it is at.
 *
 * The strip used to show two transcript rows in two 200x100 boxes, which is
 * about one sentence of a conversation the operator opened the surface to read.
 * The whole 800x100 strip is one readout instead, five rows deep, at the same
 * type size the event keys use.
 *
 * The other half of this module is the two-way tie between the strip and the
 * eight event keys. Pressing an event key already scrolled the transcript to
 * that event's header; the reverse — scrolling with knob 1 and seeing which
 * event you have scrolled into — did not exist, so the keys and the strip could
 * describe different parts of the log with nothing on the deck saying so.
 */

/** Transcript rows the full-width panel shows at once. */
export const CHAT_WINDOW_ROWS = 5;

/**
 * Which event key a transcript offset sits inside, or null when it sits above
 * the first header.
 *
 * `starts` is ascending — the daemon flattens the transcript as a header
 * followed by that event's entries, newest event first — so the event
 * containing `offset` is the last header at or before it. The returned value is
 * an *event key* position, not an index into `starts`: key 0 is the LIVE row
 * rather than an event, so event `n` is key `n + 1`.
 *
 * Null means the offset is above every header, which happens only when the feed
 * pushed entries before the header they belong to. Highlighting nothing is the
 * honest answer there; snapping to key 1 would claim the operator is reading an
 * event they are not.
 */
export const eventKeyAtOffset = (starts: readonly number[], offset: number): number | null => {
  let key: number | null = null;
  for (let index = 0; index < starts.length; index += 1) {
    if (starts[index] > offset) break;
    key = index + 1;
  }
  return key;
};

/**
 * Scroll the eight-key event window so `key` is inside it, moving as little as
 * possible. Mirrors the mock's `sdEnsureVisible`: without it, scrolling the
 * chat into an event that is off the current key page highlights a key the
 * operator cannot see, which looks exactly like the highlight being broken.
 */
export const ensureEventVisible = (offset: number, key: number, maxOffset: number): number => {
  const bounded = Math.max(0, Math.min(offset, maxOffset));
  if (key < bounded) return Math.max(0, Math.min(key, maxOffset));
  if (key > bounded + 7) return Math.max(0, Math.min(key - 7, maxOffset));
  return bounded;
};
