/**
 * Provider marks for the key faces.
 *
 * The design mock draws each key's provider as an `<img>` pointing at the same
 * SVG the dashboard serves from `priv/static`. Those files are copied into this
 * package's `assets/vendor` directory so the sidecar renders the real marks
 * rather than a stand-in, and `@napi-rs/canvas` rasterises them directly.
 *
 * Asset resolution deliberately uses `../../assets` relative to this module.
 * That single path holds in all three places this code runs: from `src/art`
 * under vitest, from `dist/art` after a local build, and from `app/dist/art`
 * inside the installed archive (where the packaging step copies `assets` to
 * `app/assets`). Each is exactly two levels below the directory holding
 * `assets`.
 *
 * A provider with no bundled mark falls back to a lettered token rather than a
 * blank space, so an unrecognised backend still reads as *something* on a
 * 120-pixel key.
 */
import { loadImage, type Image, type SKRSContext2D } from "@napi-rs/canvas";

/**
 * Provider name (as the daemon reports it) -> bundled asset filename.
 *
 * DeepSeek ships as a PNG rather than an SVG on purpose: the dashboard's
 * `deepseek.svg` is only a wrapper around an embedded
 * `<image href="data:image/png;base64,...">`, and the SVG rasteriser decodes
 * the document but does not draw embedded raster images — it loads "fine" and
 * renders nothing. The PNG is that same image, extracted.
 */
const VENDOR_ASSETS: Readonly<Record<string, string>> = Object.freeze({
  claude: "claude-symbol.svg",
  codex: "codex-color.svg",
  deepseek: "deepseek.png",
  kimi: "kimi.svg",
  openrouter: "openrouter.svg",
});

/** Token colour for a provider with no bundled mark. */
const FALLBACK_TOKEN_COLOR = "#5a6273";

/**
 * Marks decoded once and reused. Rasterising an SVG per key per repaint would
 * dominate the render cost; there are at most a handful of providers.
 */
const cache = new Map<string, Image | null>();

/** Normalises a provider name to its cache/asset key. */
const vendorKey = (vendor: string): string => vendor.trim().toLowerCase();

/**
 * Preloads the mark for `vendor`. Resolves `null` when the provider has no
 * bundled asset or the asset cannot be decoded — callers then draw the
 * lettered fallback. Never rejects: a missing logo must not fail a repaint.
 */
export const loadVendorMark = async (vendor: string): Promise<Image | null> => {
  const key = vendorKey(vendor);
  const cached = cache.get(key);
  if (cached !== undefined) {
    return cached;
  }

  const asset = VENDOR_ASSETS[key];
  if (asset === undefined) {
    cache.set(key, null);
    return null;
  }

  try {
    const image = await loadImage(new URL(`../../assets/vendor/${asset}`, import.meta.url));
    cache.set(key, image);
    return image;
  } catch {
    cache.set(key, null);
    return null;
  }
};

/** Cache key for the Aiur brand mark, which is not a provider. */
const BRAND_KEY = "__aiur__";

/** Loads the Aiur brand mark used on the summary segment. */
export const loadBrandMark = async (): Promise<Image | null> => {
  const cached = cache.get(BRAND_KEY);
  if (cached !== undefined) {
    return cached;
  }
  try {
    const image = await loadImage(new URL("../../assets/aiur-logo.png", import.meta.url));
    cache.set(BRAND_KEY, image);
    return image;
  } catch {
    cache.set(BRAND_KEY, null);
    return null;
  }
};

/** Draws the Aiur brand mark, or nothing when the asset is unavailable. */
export const drawBrandMark = (context: SKRSContext2D, x: number, y: number, size: number): void => {
  const mark = cache.get(BRAND_KEY) ?? null;
  if (mark !== null) {
    context.drawImage(mark, x, y, size, size);
  }
};

/** Preloads every bundled mark so the first repaint draws them synchronously. */
export const preloadVendorMarks = async (): Promise<void> => {
  await Promise.all([...Object.keys(VENDOR_ASSETS).map((vendor) => loadVendorMark(vendor)), loadBrandMark()]);
};

/** The already-loaded mark for `vendor`, or `null` if it is absent or pending. */
export const vendorMark = (vendor: string): Image | null => cache.get(vendorKey(vendor)) ?? null;

/**
 * Draws `vendor`'s mark as a `size`-pixel square at (`x`, `y`), falling back to
 * a filled token carrying the provider's initial.
 */
export const drawVendorMark = (
  context: SKRSContext2D,
  vendor: string,
  x: number,
  y: number,
  size: number,
): void => {
  const mark = vendorMark(vendor);
  if (mark !== null) {
    context.drawImage(mark, x, y, size, size);
    return;
  }

  const radius = size / 2;
  context.beginPath();
  context.arc(x + radius, y + radius, radius, 0, Math.PI * 2);
  context.fillStyle = FALLBACK_TOKEN_COLOR;
  context.fill();

  const initial = vendor.trim().charAt(0).toUpperCase();
  if (initial === "") {
    return;
  }
  context.fillStyle = "#f1f3f6";
  context.font = `700 ${Math.round(size * 0.68)}px sans-serif`;
  context.textAlign = "center";
  context.textBaseline = "middle";
  context.fillText(initial, x + radius, y + radius + size * 0.04);
  context.textAlign = "left";
  context.textBaseline = "alphabetic";
};
