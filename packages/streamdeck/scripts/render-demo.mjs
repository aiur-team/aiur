/**
 * Renders the demo fixture exactly as the device would, to a PNG.
 *
 * Diagnostic only. Use it to check the demo dataset and any layout change
 * before flashing the deck.
 *
 * Usage:
 *   npm run build && node scripts/render-demo.mjs [out.png] [columnOffset] [mode] [providerOffset]
 */
import { createCanvas, loadImage } from "@napi-rs/canvas";
import { writeFileSync } from "node:fs";

import { createRasterizer } from "../dist/rasterizer.js";
import { layoutKeys } from "../dist/keys.js";
import { preloadVendorMarks } from "../dist/art/vendorMark.js";
import { composeStrip } from "../dist/touchStrip/stripLayout.js";
import { summaryModel } from "../dist/touchStrip/summarySegment.js";
import { providerRows } from "../dist/touchStrip/providerPanel.js";
import { pagerModel } from "../dist/touchStrip/pagerSegment.js";
import { agentDetailModel } from "../dist/touchStrip/agentDetail.js";
import { demoGrid, demoUsage, demoLogs } from "../dist/demo.js";

const out = process.argv[2] ?? "demo.png";
const columnOffset = Number.parseInt(process.argv[3] ?? "0", 10);
// Optional third argument renders the cmd or logs strip instead of the grid,
// so a layout change to either can be eyeballed without flashing the deck.
const mode = process.argv[4] ?? "grid";
// Knob 2's scroll position, so the provider window and its chevrons can be
// eyeballed at every offset without a device.
const providerOffset = Number.parseInt(process.argv[5] ?? "0", 10);

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

const gridStrip = {
  mode: "grid",
  data: {
    summary: summaryModel(running, grid.total - running, grid.build),
    providers: providerRows(usage),
    providerOffset,
    pager: pagerModel(grid.total, 8, Math.floor(columnOffset / 4)),
    pagerLabel: `${grid.total} Agents`,
  },
};
const cmdStrip = {
  mode: "cmd",
  data: { detail: agentDetailModel({ ...grid.agents[0], runtime_seconds: 11_240, activity: "waiting_ci" }) },
};
const logsStrip = { mode: "logs", data: { rows: demoLogs().transcript.slice(0, 5), chatHasNext: true, eventHasNext: true } };
const panels = composeStrip(mode === "cmd" ? cmdStrip : mode === "logs" ? logsStrip : gridStrip);

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
// The strip is 800px wide on the device; scale the whole thing to the preview.
const scale = (width - GAP * 2) / 800;
for (const panel of panels) {
  const image = await loadImage(Buffer.from(rasterizer.segment(panel.content, panel.region.width)));
  ctx.drawImage(image, GAP + panel.region.x * scale, stripY, panel.region.width * scale, 100 * scale);
}

writeFileSync(out, canvas.toBuffer("image/png"));
console.log(`wrote ${out} (columnOffset=${columnOffset}, mode=${mode}, providerOffset=${providerOffset})`);
process.exit(0);
