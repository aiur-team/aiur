/**
 * logs-mode strip view-model: the agent's chat log, and which event it is at.
 *
 * The strip is one 800x100 readout, five rows deep, at the same type size the
 * event keys use.
 *
 * The other half of this module is the two-way tie between the strip and the
 * eight event keys: pressing an event key scrolls the transcript to that
 * event's header, and scrolling the transcript moves the highlight to whichever
 * event you have scrolled into.
 *
 * ## Reading direction
 *
 * Everything is oldest-first. Offset 0 is the ticket's origin at the far left;
 * the last offset is the newest thing the agent said, at the far right, which
 * is where LIVE lives. That is the direction any chat window is read in, and it
 * is the direction the feed now flattens in.
 */

/** Transcript rows the full-width panel shows at once. */
export const CHAT_WINDOW_ROWS = 5;

/**
 * Which key the transcript offset is currently reading.
 *
 * `starts[i]` is key `i`'s own header offset, taken straight from the feed
 * rather than recomputed here — the feed knows where it put each header, and a
 * client that re-derives them has to agree with the server about anchors,
 * padding and ordering, which is exactly the kind of agreement that silently
 * breaks.
 *
 * The last key is LIVE. Sitting on the newest row *is* being live, so the rule
 * is: at the end of the transcript, LIVE; anywhere else, the last event whose
 * header is at or before the offset. That single rule is what makes selection
 * bidirectional and mutually exclusive — press an event and LIVE goes inactive,
 * scroll back to the end and it comes back — without LIVE needing a special
 * case anywhere else.
 *
 * `null` only when there are no keys at all.
 */
export const selectedKeyAtOffset = (
  starts: readonly number[],
  offset: number,
  chatMax: number,
): number | null => {
  if (starts.length === 0) return null;
  const live = starts.length - 1;

  let key: number | null = null;
  for (let index = 0; index < live; index += 1) {
    if (starts[index] > offset) break;
    key = index;
  }

  // An event published after the agent's last word — `pr.merged`, `ci.passed`,
  // a resolved decision — has no entries under it, so its header *is* the last
  // window. Handing that offset to LIVE on position alone made those keys
  // permanently unhighlightable: the press landed correctly and lit a different
  // key. Landing exactly on a header therefore always means reading that event;
  // being at the end for any other reason means live.
  if (key !== null && starts[key] === offset) return key;
  if (offset >= chatMax) return live;
  // Above every event header can only happen if the feed omitted the origin
  // anchor. The origin exists precisely so this cannot occur; fall back to it
  // rather than leaving nothing highlighted, because "no key is active" is a
  // state this surface no longer has.
  return key ?? 0;
};

/**
 * Scroll the eight-key event window so `key` is inside it, moving as little as
 * possible. Without it, scrolling the chat into an event that is off the
 * current key page highlights a key the operator cannot see, which looks
 * exactly like the highlight being broken.
 */
export const ensureEventVisible = (offset: number, key: number, maxOffset: number): number => {
  const bounded = Math.max(0, Math.min(offset, maxOffset));
  if (key < bounded) return Math.max(0, Math.min(key, maxOffset));
  if (key > bounded + 7) return Math.max(0, Math.min(key - 7, maxOffset));
  return bounded;
};
