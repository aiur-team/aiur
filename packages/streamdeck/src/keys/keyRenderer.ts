/**
 * Key renderer — maps the eight #1350 key descriptors to per-key content,
 * encodes each, and diffs through the {@link KeyCache} so only changed keys
 * produce writes.
 *
 * It stays transport- and pixel-independent by taking the key encoder as a
 * dependency. `layoutKeys` (from #1350) decides which descriptor each key
 * shows; the injected {@link KeyEncoder} rasterises an agent descriptor to a
 * JPEG or picks a solid fill (empty keys become a black RGB fast-path fill);
 * `KeyCache` decides which changed. The renderer never performs I/O.
 *
 * Because each key is encoded and diffed on its own, re-rendering a panel whose
 * data changed for one agent yields exactly one {@link KeyPaint} and never
 * repaints the other seven — provided the encoder is deterministic for
 * unchanged descriptors, which the cache's content-identity diff assumes.
 */
import { type KeyDescriptor } from "./descriptor.js";
import { KEY_COUNT } from "./keyImage.js";
import { KeyCache, type KeyPaint } from "./keyCache.js";
import { type KeyContent } from "./keyContent.js";

/**
 * Turns one key's descriptor into its content. Must be deterministic:
 * identical `descriptor` must yield identical bytes/colour, or the cache cannot
 * recognise an unchanged key as clean. The device path supplies a canvas-backed
 * encoder; tests supply a stub.
 */
export type KeyEncoder = (descriptor: KeyDescriptor, keyIndex: number) => KeyContent;

export class KeyRenderer {
  constructor(
    private readonly encode: KeyEncoder,
    private readonly cache: KeyCache = new KeyCache(),
  ) {}

  /**
   * Encode each of the eight descriptors and return the writes for only the
   * keys whose content changed since the last render — in ascending key order.
   * A first render returns up to eight; a re-render with one changed key
   * returns exactly one.
   *
   * `descriptors` must have length {@link KEY_COUNT}; `layoutKeys` always
   * produces exactly that.
   */
  render(descriptors: readonly KeyDescriptor[]): KeyPaint[] {
    if (descriptors.length !== KEY_COUNT) {
      throw new RangeError(
        `expected ${KEY_COUNT} key descriptors, got ${descriptors.length}`,
      );
    }
    const next = new Map<number, KeyContent>();
    for (let index = 0; index < KEY_COUNT; index += 1) {
      next.set(index, this.encode(descriptors[index], index));
    }
    return this.cache.paintAll(next);
  }

  /**
   * Drop cached content for one key (or all) so its next render repaints
   * unconditionally — e.g. after a device reset clears the on-screen image.
   */
  invalidate(keyIndex?: number): void {
    this.cache.invalidate(keyIndex);
  }
}
