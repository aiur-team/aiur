/**
 * Diagnostic: render key faces via the real rasterizer for several progress
 * states and pixel-check the bar. Not part of the shipped package.
 */
import { createCanvas, loadImage } from "@napi-rs/canvas";
import { writeFileSync } from "node:fs";
import { createRasterizer } from "../dist/rasterizer.js";
import { layoutKeys } from "../dist/keys.js";

const out = process.argv[2] ?? "/tmp/eyeball-bars.png";

const agent = (identifier, bucket, progress_percent, progress_freshness) => ({
  identifier,
  title: "Eyeball",
  vendor: "claude",
  bucket,
  progress_percent,
  progress_freshness,
  priority: false,
  dependency_ready: true,
});

const states = [
  { name: "unknown", a: agent("1", "running", null, "unknown") },
  { name: "zero", a: agent("2", "running", 0, "fresh") },
  { name: "p40", a: agent("3", "running", 40, "fresh") },
  { name: "p70", a: agent("4", "running", 70, "fresh") },
  { name: "p100", a: agent("5", "running", 100, "fresh") },
  { name: "stale70", a: agent("6", "running", 70, "stale") },
];

const rasterizer = createRasterizer();
const KEY = 120;
const GAP = 10;
const canvas = createCanvas(states.length * (KEY + GAP) + GAP, KEY + GAP * 2);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#17181c";
ctx.fillRect(0, 0, canvas.width, canvas.height);

for (let i = 0; i < states.length; i += 1) {
  const descriptors = layoutKeys([states[i].a], 0);
  const jpeg = rasterizer.key(descriptors[0]);
  const img = await loadImage(jpeg);
  ctx.drawImage(img, GAP + i * (KEY + GAP), GAP);
  ctx.fillStyle = "#f1f3f6";
  ctx.font = "12px monospace";
  ctx.fillText(states[i].name, GAP + i * (KEY + GAP), KEY + GAP * 2 - 2);
}

writeFileSync(out, canvas.toBuffer("image/png"));
console.log(`wrote ${out}`);

// Pixel-check the bar region of each rendered key: sample the fill at the bar
// centre (y = ~105 in a 120px key) and report the dominant colour.
const grid = await loadImage(out);
const gc = createCanvas(grid.width, grid.height);
const gctx = gc.getContext("2d");
gctx.drawImage(grid, 0, 0);
const g = gctx.getImageData(0, 0, grid.width, grid.height);
const px = (x, y) => { const o = (y * grid.width + x) * 4; return [g.data[o], g.data[o + 1], g.data[o + 2]]; };
for (let i = 0; i < states.length; i += 1) {
  const x0 = GAP + i * (KEY + GAP);
  // Sample a horizontal run across the middle of the bar band and bucket.
  const colours = new Set();
  for (let x = x0 + 30; x < x0 + 90; x += 4) {
    colours.add(px(x, GAP + 105).join(","));
  }
  console.log(states[i].name, "bar pixels:", [...colours].slice(0, 4));
}
