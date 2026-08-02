/**
 * Content-keyed key cache with per-key dirty tracking.
 *
 * The eight keys each own an independent write. This cache holds the last
 * content painted to each key and only emits reports for keys whose content
 * actually changed. That is the mechanism behind the ticket's core guarantee:
 *
 *   - a state tick that changes ONE agent repaints exactly ONE key;
 *   - re-submitting identical content for a key produces no writes at all.
 *
 * The cache is transport-independent: it turns changed key content into the
 * ordered report sequences the write queue (`writeQueue.ts`) will later
 * serialize onto the hidraw handle. It never performs I/O and holds no device
 * handle. Callers that need to force a repaint (e.g. after a device reset drops
 * the on-screen image) call {@link invalidate}.
 */
import { KEY_COUNT, assertKeyIndex, type KeyReport } from "./keyImage.js";
import { DEFAULT_FILL_INDEX_BASE, type FillIndexBase } from "./keyFill.js";
import {
  type KeyContent,
  buildContentReports,
  cloneContent,
  contentEquals,
} from "./keyContent.js";

/**
 * A pending repaint of a single key: its index, the ordered HID reports, and a
 * {@link commit} thunk. The cache is NOT updated when the paint is produced —
 * the key stays dirty until {@link commit} runs. The write path calls
 * {@link commit} only after every report has reached the device; a failed or
 * partial write leaves it uncalled and invokes {@link discard}, so the key is
 * still dirty and repaints on the next render rather than being wrongly cached
 * as painted (which would blank it until the process restarts).
 */
export interface KeyPaint {
  readonly index: number;
  readonly reports: KeyReport[];
  readonly commit: () => void;
  /** Drop this pending desired value after a failed or cancelled write. */
  readonly discard: () => void;
  /** Invalidate this key after a partial transfer corrupts its on-device state. */
  readonly invalidate: () => void;
}

export class KeyCache {
  /** Last content per key; `undefined` means never painted. */
  private readonly current: (KeyContent | undefined)[] = new Array<KeyContent | undefined>(
    KEY_COUNT,
  ).fill(undefined);

  /**
   * Latest content already offered to the write queue for each key. This keeps
   * a slow USB transfer from making every state tick look dirty, and lets a
   * newer paint supersede an older queued/in-flight paint without an older
   * commit erasing that newer desired state.
   */
  private readonly pending: (KeyContent | undefined)[] = new Array<KeyContent | undefined>(
    KEY_COUNT,
  ).fill(undefined);

  constructor(private readonly fillIndexBase: FillIndexBase = DEFAULT_FILL_INDEX_BASE) {}

  /** True when `content` differs from the key's cached content. */
  isDirty(keyIndex: number, content: KeyContent): boolean {
    assertKeyIndex(keyIndex);
    const existing = this.pending[keyIndex] ?? this.current[keyIndex];
    return existing === undefined || !contentEquals(existing, content);
  }

  /**
   * Offer new content for one key. If it differs from the cached copy, return a
   * {@link KeyPaint} whose reports render it and whose {@link KeyPaint.commit}
   * stores a defensive snapshot; otherwise return `null`. The cache is NOT
   * mutated here — it changes only when the returned paint's `commit()` runs
   * after a successful write, so a failed write cannot leave the key cached as
   * painted when the pixels never landed.
   */
  paint(keyIndex: number, content: KeyContent): KeyPaint | null {
    assertKeyIndex(keyIndex);
    if (!this.isDirty(keyIndex, content)) return null;
    const reports = buildContentReports(keyIndex, content, this.fillIndexBase);
    const snapshot = cloneContent(content);
    this.pending[keyIndex] = snapshot;
    return {
      index: keyIndex,
      reports,
      commit: () => {
        // A later state tick may have queued different content while this
        // paint was on the USB wire. Keep that newer desired value pending so
        // its eventual commit wins; otherwise an older completion could make
        // the cache wrongly treat the key as clean.
        if (this.pending[keyIndex] === snapshot) {
          this.current[keyIndex] = snapshot;
          this.pending[keyIndex] = undefined;
        }
      },
      discard: () => {
        // A newer paint may already have replaced this desired value. Only
        // discard the same private snapshot so an older cancellation cannot
        // erase newer state that is waiting to be written.
        if (this.pending[keyIndex] === snapshot) {
          this.pending[keyIndex] = undefined;
        }
      },
      invalidate: () => {
        this.current[keyIndex] = undefined;
        this.pending[keyIndex] = undefined;
      },
    };
  }

  /**
   * Offer content for several keys at once and return paints only for the ones
   * that changed, in ascending key order. Keys absent from `next` are left
   * as-is. A full-panel render passes all eight; only the dirty ones write.
   */
  paintAll(next: ReadonlyMap<number, KeyContent>): KeyPaint[] {
    const paints: KeyPaint[] = [];
    for (let index = 0; index < KEY_COUNT; index += 1) {
      const content = next.get(index);
      if (content === undefined) continue;
      const paint = this.paint(index, content);
      if (paint !== null) paints.push(paint);
    }
    return paints;
  }

  /**
   * Drop the cached content for one key (or all keys when `keyIndex` is
   * omitted) so the next {@link paint} repaints unconditionally. Use after a
   * device reset/suspend that clears the on-screen image.
   */
  invalidate(keyIndex?: number): void {
    if (keyIndex === undefined) {
      this.current.fill(undefined);
      this.pending.fill(undefined);
      return;
    }
    assertKeyIndex(keyIndex);
    this.current[keyIndex] = undefined;
    this.pending[keyIndex] = undefined;
  }
}
