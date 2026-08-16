/**
 * Encoded-panel cache with per-panel dirty tracking.
 *
 * Each strip panel (see `stripLayout.ts`) owns an independent `0x0C`
 * partial-region write. This cache holds the last JPEG encoded for each panel
 * and only emits reports for panels whose encoded bytes actually changed. That
 * is the mechanism behind two touch-strip guarantees:
 *
 *   - a usage-meter tick that changes one panel repaints ONLY that panel;
 *   - re-submitting identical content for a panel produces no writes at all.
 *
 * ## Why a layout change drops everything
 *
 * Panels are keyed by their rectangle, and a mode change re-tiles the strip
 * with different rectangles. The stale entries would still *match* on a later
 * return to the old layout — but the pixels under them were overwritten in the
 * meantime by the wide panel that replaced them, so honouring that match would
 * skip a repaint the device needs. The cache therefore compares the whole
 * layout each render and clears when it differs. Every layout tiles the full
 * strip, so a cleared cache repaints exactly the strip and nothing is left over
 * from the previous one.
 *
 * The cache is transport-independent: it turns changed panel JPEGs into the
 * ordered report sequences the device transport serializes onto the hidraw
 * handle. It never performs I/O and holds no device handle.
 *
 * Content identity is byte equality of the encoded JPEG. Encoding is expected
 * to be deterministic, so identical content yields identical bytes and is
 * correctly treated as clean. Callers that need to force a repaint (e.g. after
 * a device reset drops the on-screen image) call {@link invalidate}.
 */
import { buildRegionReports, type Region } from "../imageWriter/headerGenerator.js";

/** A panel offered to the cache: where it goes and the bytes that fill it. */
export interface EncodedPanel {
  readonly region: Region;
  readonly jpeg: Uint8Array;
}

/** A pending repaint of a single panel: its region and ordered HID reports. */
export interface PanelPaint {
  readonly region: Region;
  readonly reports: Buffer[];
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/** Stable identity for a panel's rectangle. */
const regionKey = (region: Region): string => `${region.x},${region.y},${region.width},${region.height}`;

export class PanelCache {
  /** Last encoded JPEG per panel rectangle. */
  private readonly encoded = new Map<string, Uint8Array>();

  /** The rectangles the previous render tiled the strip with. */
  private layout = "";

  /** True when the panel's encoded content differs from the cached copy. */
  isDirty(panel: EncodedPanel): boolean {
    const current = this.encoded.get(regionKey(panel.region));
    return current === undefined || !bytesEqual(current, panel.jpeg);
  }

  /**
   * Offer new content for one panel. If it differs from the cached copy, store
   * it and return the ordered reports for its region; otherwise return `null`
   * and leave the cache untouched — the panel is not repainted.
   */
  paint(panel: EncodedPanel): Buffer[] | null {
    if (!this.isDirty(panel)) return null;
    // Defensive copy so a later mutation of the caller's buffer cannot silently
    // desync the cached identity from what was actually written.
    this.encoded.set(regionKey(panel.region), Uint8Array.prototype.slice.call(panel.jpeg));
    return buildRegionReports(panel.region, panel.jpeg);
  }

  /**
   * Offer a whole strip layout at once and return paints only for the panels
   * that changed, in the given order. A layout whose rectangles differ from the
   * previous render repaints in full, for the reason in the module docs.
   */
  paintAll(panels: readonly EncodedPanel[]): PanelPaint[] {
    const layout = panels.map((panel) => regionKey(panel.region)).join("|");
    if (layout !== this.layout) {
      this.encoded.clear();
      this.layout = layout;
    }
    const paints: PanelPaint[] = [];
    for (const panel of panels) {
      const reports = this.paint(panel);
      if (reports !== null) paints.push({ region: panel.region, reports });
    }
    return paints;
  }

  /**
   * Drop every cached panel so the next render repaints unconditionally. Use
   * after a device reset/suspend that clears the on-screen image.
   */
  invalidate(): void {
    this.encoded.clear();
  }
}
