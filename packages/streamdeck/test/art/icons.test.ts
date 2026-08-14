import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { BUILD_ORDER_ICONS, DEFAULT_ICON, drawIcon, iconFragment } from "../../src/art/icons.js";

/** Counts non-background pixels, i.e. whether anything was actually drawn. */
const inkedPixels = (draw: (context: ReturnType<ReturnType<typeof createCanvas>["getContext"]>) => void): number => {
  const canvas = createCanvas(24, 24);
  const context = canvas.getContext("2d");
  context.fillStyle = "#000000";
  context.fillRect(0, 0, 24, 24);
  draw(context);
  const { data } = context.getImageData(0, 0, 24, 24);
  let inked = 0;
  for (let i = 0; i < data.length; i += 4) {
    if (data[i] > 20 || data[i + 1] > 20 || data[i + 2] > 20) inked += 1;
  }
  return inked;
};

describe("iconFragment", () => {
  it("resolves a known lane to its own fragment", () => {
    expect(iconFragment("shield")).toBe(BUILD_ORDER_ICONS.shield);
  });

  it("falls back to the default icon for an unknown or missing lane", () => {
    expect(iconFragment("not-a-lane")).toBe(BUILD_ORDER_ICONS[DEFAULT_ICON]);
    expect(iconFragment(null)).toBe(BUILD_ORDER_ICONS[DEFAULT_ICON]);
    expect(iconFragment(undefined)).toBe(BUILD_ORDER_ICONS[DEFAULT_ICON]);
  });
});

describe("drawIcon", () => {
  // A fragment that silently draws nothing looks identical to a missing icon on
  // the device, so assert every lane in the set actually puts ink down.
  it("draws visible strokes for every icon in the set", () => {
    for (const [lane, fragment] of Object.entries(BUILD_ORDER_ICONS)) {
      const inked = inkedPixels((context) => drawIcon(context, fragment, 0, 0, 24, "#ffffff"));
      expect(inked, `icon ${lane} drew nothing`).toBeGreaterThan(0);
    }
  });

  it("covers path, circle, rect and ellipse primitives", () => {
    // `database` is the only fragment using <ellipse>; `components` uses <rect>;
    // `flow` uses <circle>. All three must render.
    for (const lane of ["database", "components", "flow"]) {
      expect(inkedPixels((context) => drawIcon(context, BUILD_ORDER_ICONS[lane], 0, 0, 24, "#ffffff"))).toBeGreaterThan(0);
    }
  });

  it("leaves the canvas state unchanged for the caller", () => {
    const context = createCanvas(24, 24).getContext("2d");
    context.strokeStyle = "#123456";
    context.lineWidth = 9;
    drawIcon(context, BUILD_ORDER_ICONS.list, 0, 0, 24, "#ffffff");
    expect(context.strokeStyle).toBe("#123456");
    expect(context.lineWidth).toBe(9);
  });
});
