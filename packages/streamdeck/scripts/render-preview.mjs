/**
 * Renders a sample deck face to a PNG so a human can look at it.
 *
 * Diagnostic only. The unit tests prove the descriptor pipeline; they cannot
 * tell you the ticket number is too big or the title is clipped. This composes
 * the eight keys and the touch strip exactly as the sidecar would, at true
 * device pixel sizes, and writes one image with the strip below the keys.
 *
 * Usage:
 *   npm run build && node scripts/render-preview.mjs [out.png]
 */
import { createCanvas, loadImage } from "@napi-rs/canvas";
import { writeFileSync } from "node:fs";

import { createRasterizer } from "../dist/rasterizer.js";
import { layoutKeys } from "../dist/keys.js";
import { preloadVendorMarks } from "../dist/art/vendorMark.js";
import { composeStrip } from "../dist/touchStrip/stripLayout.js";

const out = process.argv[2] ?? "preview.png";

// Shaped after the real fleet on the operator's deck: mixed providers, mixed
// buckets, every progress freshness/edge state, a blocked queued ticket, and a
// long title. Keeping unknown, zero, stale, ordinary and complete together
// makes this the visual regression sheet for progress rendering.
const agents = [
  { identifier: "1437", title: "Measured zero progress", vendor: "deepseek", icon: "flow", bucket: "running", progress_percent: 0, progress_freshness: "fresh", priority: false, dependency_ready: true },
  { identifier: "1674", title: "Ordinary progress fill", vendor: "codex", icon: "shield", bucket: "alert", progress_percent: 50, progress_freshness: "fresh", priority: true, dependency_ready: true },
  { identifier: "1682", title: "Unknown progress reading", vendor: "codex", icon: "pipeline", bucket: "running", progress_percent: null, progress_freshness: "unknown", priority: false, dependency_ready: true },
  { identifier: "1717", title: "Retained stale progress", vendor: "claude", icon: "alert", bucket: "stuck", progress_percent: 70, progress_freshness: "stale", priority: false, dependency_ready: true },
  { identifier: "1481", title: "Nearly complete work", vendor: "deepseek", icon: "book", bucket: "paused", progress_percent: 99, progress_freshness: "fresh", priority: false, dependency_ready: true },
  { identifier: "1677", title: "Completed work", vendor: "codex", icon: "cloud", bucket: "running", progress_percent: 100, progress_freshness: "fresh", priority: false, dependency_ready: true },
  { identifier: "1693", title: "Daemon boots without a workspace", vendor: "kimi", icon: "database", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
  { identifier: "1793", title: "Tickets filed by the executor", vendor: "openrouter", icon: "list", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: false },
];

await preloadVendorMarks();
const rasterizer = createRasterizer();

const KEY = 120;
const GAP = 10;
const STRIP_W = 800;
const STRIP_H = 100;
const width = KEY * 4 + GAP * 5;
const height = GAP + KEY * 2 + GAP + STRIP_H + GAP;

const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#17181c";
ctx.fillRect(0, 0, width, height);

const descriptors = layoutKeys(agents, 0);
for (let i = 0; i < 8; i += 1) {
  const jpeg = rasterizer.key(descriptors[i]);
  const image = await loadImage(Buffer.from(jpeg));
  const col = i % 4;
  const row = i < 4 ? 0 : 1;
  ctx.drawImage(image, GAP + col * (KEY + GAP), GAP + row * (KEY + GAP), KEY, KEY);
}

// Compose the strip straight from its layout so the preview exercises the same
// four SegmentContent descriptors the device path paints.
const stripY = GAP + KEY * 2 + GAP;
const hour = 60 * 60 * 1000;
const panels = composeStrip({
  mode: "grid",
  data: {
    summary: {
      live: 4,
      remaining: 28,
      build: { completed: 13, total: 32, fraction: 13 / 32, etaLabel: "58m" },
    },
    providers: [
      {
        label: "claude",
        model: {
          provider: "claude",
          hasData: true,
          freshness: "fresh",
          session: { usedPercent: 28, resetsAt: new Date(Date.now() + 22 * 60 * 1000).toISOString() },
          weekly: { usedPercent: 47, resetsAt: new Date(Date.now() + 52 * hour).toISOString() },
        },
      },
      {
        label: "codex",
        model: {
          provider: "codex",
          hasData: true,
          freshness: "fresh",
          session: { usedPercent: 19, resetsAt: new Date(Date.now() + 40 * 60 * 1000).toISOString() },
          weekly: { usedPercent: 31, resetsAt: new Date(Date.now() + 70 * hour).toISOString() },
        },
      },
    ],
    providerOffset: 0,
    pager: { windowCount: 4, currentWindow: 0, dots: [true, false, false, false], hasMultiple: true },
    pagerLabel: "32 agents",
  },
});

const scale = (width - GAP * 2) / STRIP_W;
for (const panel of panels) {
  const image = await loadImage(Buffer.from(rasterizer.segment(panel.content, panel.region.width)));
  // The preview scales the 800px strip to the key row's width so both fit one
  // image; on the device every panel is drawn 1:1.
  ctx.drawImage(image, GAP + panel.region.x * scale, stripY, panel.region.width * scale, STRIP_H * scale);
}

writeFileSync(out, canvas.toBuffer("image/png"));
console.log(`wrote ${out} (${width}x${height})`);
process.exit(0);
