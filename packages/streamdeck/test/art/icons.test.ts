import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import {
  BUILD_ORDER_ICONS,
  COMMAND_ICONS,
  DEFAULT_ICON,
  ACTIVITY_ICONS,
  activityFragment,
  commandFragment,
  commandIsFilled,
  drawIcon,
  iconFragment,
} from "../../src/art/icons.js";

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

/** Red-channel brightness of one pixel, for telling a fill from an outline. */
const brightnessAt = (
  draw: (context: ReturnType<ReturnType<typeof createCanvas>["getContext"]>) => void,
  x: number,
  y: number,
): number => {
  const context = createCanvas(24, 24).getContext("2d");
  context.fillStyle = "#000000";
  context.fillRect(0, 0, 24, 24);
  draw(context);
  return context.getImageData(x, y, 1, 1).data[0];
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

  it("draws every command glyph, filled or stroked as the mock draws it", () => {
    for (const [command, fragment] of Object.entries(COMMAND_ICONS)) {
      const inked = inkedPixels((context) =>
        drawIcon(context, fragment, 0, 0, 24, "#ffffff", commandIsFilled(command)),
      );
      expect(inked, `command ${command} drew nothing`).toBeGreaterThan(0);
    }
  });

  // Stroking a glyph the mock fills paints a hollow outline — a play triangle
  // with a hole in it — so the interior is what tells the two modes apart.
  it("fills the interior of a filled path glyph instead of outlining it", () => {
    // (11, 12) sits well inside the play triangle and clear of its stroke.
    expect(brightnessAt((context) => drawIcon(context, COMMAND_ICONS.play, 0, 0, 24, "#ffffff", true), 11, 12)).toBeGreaterThan(200);
    expect(brightnessAt((context) => drawIcon(context, COMMAND_ICONS.play, 0, 0, 24, "#ffffff", false), 11, 12)).toBeLessThan(20);
  });

  it("fills non-path primitives too when the glyph is filled", () => {
    // `pause` is two <rect>s, so it exercises the filled branch of the shared
    // primitive painter rather than the Path2D one `play` uses. (8, 12) is
    // inside the left bar.
    expect(brightnessAt((context) => drawIcon(context, COMMAND_ICONS.pause, 0, 0, 24, "#ffffff", true), 8, 12)).toBeGreaterThan(200);
    expect(brightnessAt((context) => drawIcon(context, COMMAND_ICONS.pause, 0, 0, 24, "#ffffff", false), 8, 12)).toBeLessThan(20);
  });

  // Adding an element to the mock must degrade to a missing shape, never to a
  // throw that takes the whole key repaint with it.
  it("skips an element it does not know how to trace", () => {
    expect(() =>
      drawIcon(createCanvas(24, 24).getContext("2d"), '<polygon points="0,0 4,4"/>', 0, 0, 24, "#ffffff"),
    ).not.toThrow();
    expect(inkedPixels((context) => drawIcon(context, '<polygon points="0,0 4,4"/>', 0, 0, 24, "#ffffff"))).toBe(0);
  });

  it("skips a path element carrying no geometry", () => {
    expect(inkedPixels((context) => drawIcon(context, '<path fill="none"/>', 0, 0, 24, "#ffffff"))).toBe(0);
  });

  // A fragment missing an attribute must default it rather than produce NaN
  // geometry, which canvas silently drops — an invisible icon on the device.
  it("defaults missing primitive attributes to zero instead of NaN", () => {
    for (const fragment of ["<circle/>", "<ellipse/>", "<rect/>"]) {
      expect(() =>
        drawIcon(createCanvas(24, 24).getContext("2d"), fragment, 0, 0, 24, "#ffffff"),
      ).not.toThrow();
    }
    // A radius-less circle with an explicit centre still traces nothing
    // visible, but a sized rect with no rx must draw.
    expect(inkedPixels((context) => drawIcon(context, '<rect x="2" y="2" width="20" height="20"/>', 0, 0, 24, "#fff"))).toBeGreaterThan(0);
  });
});

describe("activityFragment", () => {
  it("resolves each activity glyph", () => {
    for (const glyph of ["brainstorm", "plan", "work", "review", "waiting"]) {
      expect(activityFragment(glyph)).toBe(ACTIVITY_ICONS[glyph]);
      expect(ACTIVITY_ICONS[glyph].length).toBeGreaterThan(0);
    }
  });

  // Unlike a lane or a command, there is no sensible default activity: drawing
  // one would claim the agent is doing something the daemon never said.
  it("draws nothing for an absent or unknown activity", () => {
    expect(activityFragment("napping")).toBe("");
    expect(activityFragment(null)).toBe("");
    expect(activityFragment(undefined)).toBe("");
  });
});

describe("commandFragment", () => {
  it("resolves a known command to its own glyph", () => {
    expect(commandFragment("play")).toBe(COMMAND_ICONS.play);
  });

  it("falls back to the logs bars for an unknown or missing command", () => {
    expect(commandFragment("teleport")).toBe(COMMAND_ICONS.logs);
    expect(commandFragment(null)).toBe(COMMAND_ICONS.logs);
    expect(commandFragment(undefined)).toBe(COMMAND_ICONS.logs);
  });
});

describe("commandIsFilled", () => {
  it("marks only the solid glyphs as filled", () => {
    expect(commandIsFilled("play")).toBe(true);
    expect(commandIsFilled("pause")).toBe(true);
    expect(commandIsFilled("back")).toBe(false);
    expect(commandIsFilled(null)).toBe(false);
    expect(commandIsFilled(undefined)).toBe(false);
  });
});
