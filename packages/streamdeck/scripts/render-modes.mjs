/**
 * Renders the cmd and logs key surfaces to a PNG for visual inspection.
 *
 * Companion to render-preview.mjs, which covers the grid. Diagnostic only.
 *
 * Usage:
 *   npm run build && node scripts/render-modes.mjs [out.png]
 */
import { createCanvas, loadImage } from "@napi-rs/canvas";
import { writeFileSync } from "node:fs";

import { createRasterizer } from "../dist/rasterizer.js";
import { layoutPhysicalKeys } from "../dist/keys.js";
import { preloadVendorMarks } from "../dist/art/vendorMark.js";

const out = process.argv[2] ?? "modes.png";
await preloadVendorMarks();
const rasterizer = createRasterizer();

const command = (name, title, icon, subLabel) => ({
  identifier: `1682:${name}`,
  title,
  vendor: "command",
  icon,
  role: "command",
  subLabel,
  bucket: "queued",
  progress_percent: 0,
  priority: false,
  dependency_ready: true,
});

const event = (index, direction, text, time = "3m") => ({
  identifier: `event-${index}`,
  title: text,
  vendor: "logs",
  icon: "",
  role: direction === "LIVE" ? "live" : "event",
  subLabel: direction,
  timeLabel: direction === "LIVE" ? "" : time,
  bucket: "queued",
  progress_percent: 0,
  priority: false,
  dependency_ready: true,
});

const rows = [
  layoutPhysicalKeys([
    command("pause", "Pause", "pause", "HOLD"),
    command("priority", "Prioritize", "up", "RAISE"),
    command("logs", "Logs", "logs", "OPEN"),
    command("mic", "Mic", "mic", "LIVE"),
  ]),
  layoutPhysicalKeys([
    event(0, "LIVE", "LIVE"),
    event(1, "EMIT", "Dependency cleared for #1682", "3m"),
    event(2, "SYSTEM", "Daemon reloaded workflow fixtures", "12m"),
    event(3, "AGENT", "Opened PR #1904 for review", "1h"),
  ]),
];

const KEY = 120;
const GAP = 10;
const width = KEY * 4 + GAP * 5;
const height = GAP + rows.length * (KEY + GAP);
const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#17181c";
ctx.fillRect(0, 0, width, height);

for (let row = 0; row < rows.length; row += 1) {
  for (let col = 0; col < 4; col += 1) {
    const image = await loadImage(Buffer.from(rasterizer.key(rows[row][col])));
    ctx.drawImage(image, GAP + col * (KEY + GAP), GAP + row * (KEY + GAP), KEY, KEY);
  }
}

writeFileSync(out, canvas.toBuffer("image/png"));
console.log(`wrote ${out} (${width}x${height})`);
process.exit(0);
