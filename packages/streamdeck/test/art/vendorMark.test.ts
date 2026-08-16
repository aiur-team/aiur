import { createCanvas } from "@napi-rs/canvas";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The decoded marks live in a module-level cache, so every test imports the
 * module fresh. Otherwise a test that populates the cache decides the result of
 * the next one — including the negative-cache and fallback cases, which are
 * only observable on a cold cache.
 */
const freshModule = async (): Promise<typeof import("../../src/art/vendorMark.js")> => {
  vi.resetModules();
  return import("../../src/art/vendorMark.js");
};

type Context = ReturnType<ReturnType<typeof createCanvas>["getContext"]>;

/** Paints onto a black 32x32 backdrop and returns the pixels. */
const painted = (draw: (context: Context) => void): Uint8ClampedArray => {
  const context = createCanvas(32, 32).getContext("2d");
  context.fillStyle = "#000000";
  context.fillRect(0, 0, 32, 32);
  draw(context);
  return context.getImageData(0, 0, 32, 32).data;
};

/** Counts pixels brighter than `threshold`, i.e. whether a mark landed. */
const brighterThan = (pixels: Uint8ClampedArray, threshold: number): number => {
  let count = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    if (pixels[i] > threshold || pixels[i + 1] > threshold || pixels[i + 2] > threshold) count += 1;
  }
  return count;
};

/** Counts pixels that are not the black backdrop, i.e. whether a mark landed. */
const inkedPixels = (draw: (context: Context) => void): number => brighterThan(painted(draw), 8);

beforeEach(() => {
  vi.resetModules();
});

afterEach(() => {
  vi.doUnmock("@napi-rs/canvas");
  vi.resetModules();
});

describe("loadVendorMark", () => {
  it("decodes every bundled provider asset", async () => {
    const { loadVendorMark } = await freshModule();
    for (const vendor of ["claude", "codex", "deepseek", "kimi", "openrouter"]) {
      await expect(loadVendorMark(vendor), `${vendor} did not decode`).resolves.not.toBeNull();
    }
  });

  it("normalises the provider name the daemon sends", async () => {
    const { loadVendorMark, vendorMark } = await freshModule();
    await loadVendorMark("  Claude  ");
    expect(vendorMark("claude")).not.toBeNull();
  });

  it("resolves null for a provider with no bundled mark", async () => {
    const { loadVendorMark, vendorMark } = await freshModule();
    await expect(loadVendorMark("zephyr")).resolves.toBeNull();
    expect(vendorMark("zephyr")).toBeNull();
  });

  // Re-decoding an SVG per key per repaint would dominate the render cost, and
  // a provider with no mark must not retry the lookup on every frame either.
  it("decodes each mark once and remembers the misses too", async () => {
    const loadImage = vi.fn(async () => ({ width: 1, height: 1 }));
    vi.doMock("@napi-rs/canvas", async () => ({
      ...(await vi.importActual<typeof import("@napi-rs/canvas")>("@napi-rs/canvas")),
      loadImage,
    }));
    const { loadVendorMark } = await freshModule();

    await loadVendorMark("claude");
    await loadVendorMark("claude");
    expect(loadImage).toHaveBeenCalledTimes(1);

    await loadVendorMark("zephyr");
    await loadVendorMark("zephyr");
    expect(loadImage).toHaveBeenCalledTimes(1);
  });

  // A missing or corrupt logo must degrade to the lettered token. A rejection
  // here would propagate out of the preload and fail the whole repaint.
  it("never rejects when the asset cannot be decoded", async () => {
    vi.doMock("@napi-rs/canvas", async () => ({
      ...(await vi.importActual<typeof import("@napi-rs/canvas")>("@napi-rs/canvas")),
      loadImage: () => Promise.reject(new Error("corrupt asset")),
    }));
    const { loadVendorMark, loadBrandMark } = await freshModule();
    await expect(loadVendorMark("claude")).resolves.toBeNull();
    await expect(loadBrandMark()).resolves.toBeNull();
  });
});

describe("loadBrandMark", () => {
  it("decodes the Aiur logo once and reuses it", async () => {
    const { loadBrandMark } = await freshModule();
    const first = await loadBrandMark();
    expect(first).not.toBeNull();
    expect(await loadBrandMark()).toBe(first);
  });
});

describe("preloadVendorMarks", () => {
  it("makes every bundled mark available synchronously afterwards", async () => {
    const { preloadVendorMarks, vendorMark } = await freshModule();
    await preloadVendorMarks();
    for (const vendor of ["claude", "codex", "deepseek", "kimi", "openrouter"]) {
      expect(vendorMark(vendor), `${vendor} was not preloaded`).not.toBeNull();
    }
  });
});

describe("drawBrandMark", () => {
  it("draws nothing before the logo has loaded", async () => {
    const { drawBrandMark } = await freshModule();
    expect(inkedPixels((context) => drawBrandMark(context, 0, 0, 32))).toBe(0);
  });

  it("draws the logo once it is loaded", async () => {
    const { drawBrandMark, loadBrandMark } = await freshModule();
    await loadBrandMark();
    expect(inkedPixels((context) => drawBrandMark(context, 0, 0, 32))).toBeGreaterThan(0);
  });
});

describe("drawVendorMark", () => {
  it("draws the real mark when it is loaded", async () => {
    const { drawVendorMark, loadVendorMark } = await freshModule();
    await loadVendorMark("claude");
    expect(inkedPixels((context) => drawVendorMark(context, "claude", 0, 0, 32))).toBeGreaterThan(0);
  });

  // An unrecognised backend still has to read as *something* on a 120-pixel
  // key, so the fallback token carries the provider's initial.
  it("falls back to a lettered token for an unknown provider", async () => {
    const { drawVendorMark } = await freshModule();
    const zephyr = painted((context) => drawVendorMark(context, "zephyr", 0, 0, 32));
    const blank = painted((context) => drawVendorMark(context, "", 0, 0, 32));
    // Both draw the token circle, which is mid-grey; only the named provider
    // adds the near-white "Z" on top of it.
    expect(brighterThan(zephyr, 8)).toBeGreaterThan(0);
    expect(brighterThan(blank, 8)).toBeGreaterThan(0);
    expect(brighterThan(zephyr, 0x90)).toBeGreaterThan(0);
    expect(brighterThan(blank, 0x90)).toBe(0);
  });

  // The token is centred text; leaving the context centred would misplace
  // whatever the caller draws next.
  it("restores the default text alignment after drawing the token", async () => {
    const { drawVendorMark } = await freshModule();
    const context = createCanvas(32, 32).getContext("2d");
    context.textAlign = "right";
    context.textBaseline = "top";
    drawVendorMark(context, "zephyr", 0, 0, 32);
    expect(context.textAlign).toBe("left");
    expect(context.textBaseline).toBe("alphabetic");
  });
});
