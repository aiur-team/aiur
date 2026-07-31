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
import { KEY_COUNT, assertKeyIndex } from "./keyImage.js";
import { DEFAULT_FILL_INDEX_BASE, type FillIndexBase } from "./keyFill.js";
import {
  type KeyContent,
  buildContentReports,
  cloneContent,
  contentEquals,
} from "./keyContent.js";

/** A pending repaint of a single key: its index and ordered HID reports. */
export interface KeyPaint {
  readonly index: number;
  readonly reports: Buffer[];
}

export class KeyCache {
  /** Last content per key; `undefined` means never painted. */
  private readonly current: (KeyContent | undefined)[] = new Array<KeyContent | undefined>(
    KEY_COUNT,
  ).fill(undefined);

  constructor(private readonly fillIndexBase: FillIndexBase = DEFAULT_FILL_INDEX_BASE) {}

  /** True when `content` differs from the key's cached content. */
  isDirty(keyIndex: number, content: KeyContent): boolean {
    assertKeyIndex(keyIndex);
    const existing = this.current[keyIndex];
    return existing === undefined || !contentEquals(existing, content);
  }

  /**
   * Offer new content for one key. If it differs from the cached copy, store a
   * defensive snapshot and return the ordered reports; otherwise return `null`
   * and leave the cache untouched — the key is not repainted.
   */
  paint(keyIndex: number, content: KeyContent): Buffer[] | null {
    assertKeyIndex(keyIndex);
    if (!this.isDirty(keyIndex, content)) return null;
    this.current[keyIndex] = cloneContent(content);
    return buildContentReports(keyIndex, content, this.fillIndexBase);
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
      const reports = this.paint(index, content);
      if (reports !== null) paints.push({ index, reports });
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
      return;
    }
    assertKeyIndex(keyIndex);
    this.current[keyIndex] = undefined;
  }
}
