/**
 * Renders the demo fixture exactly as the device would, to a PNG.
 *
 * Diagnostic only. Use it to check the demo dataset and any layout change
 * before flashing the deck.
 *
 * Usage:
 *   npm run build && node scripts/render-demo.mjs [out.png] [columnOffset]
 */
import { createCanvas, loadImage } from "@napi-rs/canvas";
import { writeFileSync } from "node:fs";

import { createRasterizer } from "../dist/rasterizer.js";
import { layoutKeys } from "../dist/keys.js";
import { preloadVendorMarks } from "../dist/art/vendorMark.js";
import { composeStrip } from "../dist/touchStrip/stripLayout.js";
import { summaryModel } from "../dist/touchStrip/summarySegment.js";
import { providerSegmentModel } from "../dist/touchStrip/providerSegment.js";
import { pagerModel } from "../dist/touchStrip/pagerSegment.js";
import { demoGrid, demoUsage } from "../dist/demo.js";

const out = process.argv[2] ?? "demo.png";
const columnOffset = Number.parseInt(process.argv[3] ?? "0", 10);

await preloadVendorMarks();
const rasterizer = createRasterizer();

const grid = demoGrid();
const usage = demoUsage(Date.now());

// Mirror surface.ts: the same projections the device path builds.
const agents = grid.agents.map((agent) => ({
  identifier: String(agent.identifier ?? ""),
  title: typeof agent.title === "string" ? agent.title : "",
  vendor: typeof agent.vendor === "string" ? agent.vendor : "unknown",
  icon: typeof agent.icon === "string" ? agent.icon : "",
  bucket: agent.bucket,
  progress_percent: agent.progress_percent,
  priority: agent.priority === true,
  dependency_ready: agent.dependency_ready === true,
}));
const running = grid.agents.filter((a) => a.bucket === "running").length;

const contents = composeStrip({
  mode: "grid",
  data: {
    summary: summaryModel(running, grid.total - running, grid.build),
    claude: providerSegmentModel(usage.claude ?? null),
    codex: providerSegmentModel(usage.codex ?? null),
    pager: pagerModel(grid.total, 8, Math.floor(columnOffset / 4)),
    pagerLabel: `${grid.total} Agents`,
  },
});

const KEY = 120;
const GAP = 10;
const width = KEY * 4 + GAP * 5;
const height = GAP + KEY * 2 + GAP + 100 + GAP;
const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#17181c";
ctx.fillRect(0, 0, width, height);

const descriptors = layoutKeys(agents, columnOffset);
for (let i = 0; i < 8; i += 1) {
  const image = await loadImage(Buffer.from(rasterizer.key(descriptors[i])));
  ctx.drawImage(image, GAP + (i % 4) * (KEY + GAP), GAP + (i < 4 ? 0 : 1) * (KEY + GAP), KEY, KEY);
}

const stripY = GAP + KEY * 2 + GAP;
const scaled = (width - GAP * 2) / 4;
for (let i = 0; i < contents.length; i += 1) {
  const image = await loadImage(Buffer.from(rasterizer.segment(contents[i])));
  ctx.drawImage(image, GAP + i * scaled, stripY, scaled, 100 * (scaled / 200));
}

writeFileSync(out, canvas.toBuffer("image/png"));
console.log(`wrote ${out} (columnOffset=${columnOffset})`);
process.exit(0);
