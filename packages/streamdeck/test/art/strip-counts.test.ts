import { createCanvas, GlobalFonts, loadImage } from "@napi-rs/canvas";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, it, onTestFinished } from "vitest";

// Future regression guard for rasterization; ExUnit separately pins the production SVG.
it("future regression guard: rasterizes the server count-strip fixture to the approved 800x100 PNG", async () => {
  const font = fileURLToPath(new URL("../../../aiur-style/fonts/JetBrainsMono-Variable.woff2", import.meta.url));
  const registered = GlobalFonts.registerFromPath(font, "JetBrains Mono");
  expect(registered).toBeTruthy();
  if (registered) onTestFinished(() => { GlobalFonts.remove(registered); });
  const fixture = new URL("../../../../src/test/fixtures/streamdeck/strip-counts.svg", import.meta.url);
  const image = await loadImage(readFileSync(fixture));
  const canvas = createCanvas(800, 100);
  canvas.getContext("2d").drawImage(image, 0, 0);
  const golden = await loadImage(readFileSync(new URL("strip-counts.png", fixture)));
  const expected = createCanvas(800, 100);
  expected.getContext("2d").drawImage(golden, 0, 0);
  expect(canvas.getContext("2d").getImageData(0, 0, 800, 100).data)
    .toEqual(expected.getContext("2d").getImageData(0, 0, 800, 100).data);
});
