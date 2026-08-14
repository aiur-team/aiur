/**
 * Touch-strip renderer — composes a mode into panels, encodes each to a JPEG,
 * and diffs through the {@link PanelCache} so only changed panels produce
 * `0x0C` region writes.
 *
 * This is the integrating layer over the pure pieces: `stripLayout` decides
 * which panels a mode tiles the strip with, `PanelCache` decides which changed,
 * and `headerGenerator` (via the cache) encodes the region writes. It stays
 * transport- and pixel-independent by taking the panel encoder as a dependency,
 * and never performs I/O.
 *
 * Panels are independent by construction: each is encoded and diffed on its
 * own, so re-rendering a mode whose data changed in one panel (a provider-usage
 * tick, one pager dot) yields exactly one `PanelPaint` and never repaints the
 * others — provided the encoder is deterministic for unchanged content, which
 * the cache's byte-identity diff assumes. A mode change re-tiles the strip and
 * therefore repaints all of it, which is both unavoidable and rare.
 */
import type { Region } from "../imageWriter/headerGenerator.js";
import { PanelCache, type PanelPaint } from "./panelCache.js";
import { composeStrip, type SegmentContent, type StripData } from "./stripLayout.js";

/**
 * Encodes one panel's structured content to a JPEG covering `region`. Must be
 * deterministic: identical `content` must yield identical bytes, or the cache
 * cannot recognise an unchanged panel as clean.
 */
export type SegmentEncoder = (content: SegmentContent, region: Region) => Uint8Array;

export class StripRenderer {
  constructor(
    private readonly encode: SegmentEncoder,
    private readonly cache: PanelCache = new PanelCache(),
  ) {}

  /**
   * Compose `input` into panels, encode each, and return the region writes for
   * only the panels whose encoded bytes changed since the last render, in
   * layout order. A first render returns all of them; a re-render with one
   * changed panel returns exactly one.
   */
  render(input: StripData): PanelPaint[] {
    return this.cache.paintAll(
      composeStrip(input).map((panel) => ({ region: panel.region, jpeg: this.encode(panel.content, panel.region) })),
    );
  }

  /**
   * Drop cached content so the next render repaints unconditionally — e.g.
   * after a device reset clears the on-screen image.
   */
  invalidate(): void {
    this.cache.invalidate();
  }
}
