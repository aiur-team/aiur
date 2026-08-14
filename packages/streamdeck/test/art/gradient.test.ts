import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it } from "vitest";

import { asColor, createPaint, parseGradient } from "../../src/art/gradient.js";
import { KEY_FACE_CONTRACT } from "../../src/key-face-contract.js";

describe("parseGradient", () => {
  it("parses the two-stop vertical gradient the contract uses", () => {
    expect(parseGradient("linear-gradient(180deg,#3f8bff,#7b4bf5)")).toEqual({
      degrees: 180,
      stops: ["#3f8bff", "#7b4bf5"],
    });
  });

  it("returns null for a plain colour so callers fall back to a solid fill", () => {
    expect(parseGradient("#9fd0ff")).toBeNull();
  });

  // A gradient whose stop list is empty parses structurally but paints nothing,
  // so it must be reported as unparsed and fall back to a solid colour rather
  // than produce a CanvasGradient with no stops — which renders transparent.
  it("returns null for a gradient with no colour stops", () => {
    expect(parseGradient("linear-gradient(180deg, , )")).toBeNull();
  });

  // Every bucket in the shared contract must be paintable; a token this module
  // cannot parse would silently render as a black key on the device.
  it("parses every glow and face token in the key-face contract", () => {
    for (const style of Object.values(KEY_FACE_CONTRACT.states)) {
      expect(parseGradient(style.glow), style.glow).not.toBeNull();
      expect(parseGradient(style.face), style.face).not.toBeNull();
    }
  });
});

describe("asColor", () => {
  it("adds the missing hash to a bare hex token", () => {
    expect(asColor("9fd0ff")).toBe("#9fd0ff");
  });

  it("leaves an already-qualified colour alone", () => {
    expect(asColor("#9fd0ff")).toBe("#9fd0ff");
    expect(asColor("rgba(255,255,255,0.08)")).toBe("rgba(255,255,255,0.08)");
  });
});

describe("createPaint", () => {
  const context = createCanvas(120, 120).getContext("2d");

  it("returns a CanvasGradient for a gradient token", () => {
    const paint = createPaint(context, "linear-gradient(180deg,#3f8bff,#7b4bf5)", 0, 0, 120, 120);
    expect(typeof paint).not.toBe("string");
  });

  it("returns a colour string for a solid token", () => {
    expect(createPaint(context, "#9fd0ff", 0, 0, 120, 120)).toBe("#9fd0ff");
  });

  // Assigning a raw `linear-gradient(...)` string to fillStyle is ignored by
  // canvas, leaving the previous fill in place. Painting the real gradient is
  // what stops every key rendering black.
  // Dividing by a zero span would put the single stop at NaN, which canvas
  // rejects; a one-stop gradient has to become a flat fill of that colour.
  it("places a single stop at the start of the axis", () => {
    const gradient = createPaint(context, "linear-gradient(180deg,#3f8bff)", 0, 0, 120, 120);
    expect(typeof gradient).not.toBe("string");
    context.fillStyle = "#000000";
    context.fillStyle = gradient as CanvasGradient;
    expect(context.fillStyle).not.toBe("#000000");
  });

  it("produces a fillStyle canvas actually accepts", () => {
    const gradient = createPaint(context, "linear-gradient(180deg,#3f8bff,#7b4bf5)", 0, 0, 120, 120);
    context.fillStyle = "#000000";
    context.fillStyle = gradient as CanvasGradient;
    expect(context.fillStyle).not.toBe("#000000");
  });
});
