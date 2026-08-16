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
import { layoutKeys, layoutPhysicalKeys } from "../dist/keys.js";
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
const logs = demoLogs();
// The logs preview opens where the device opens: at the live end. Pass a
// transcript offset as the seventh argument to inspect any other window —
// the diff rows and the tool rows sit further back than the last five.
const logsChatOffset = Math.max(
  0,
  Math.min(Number.parseInt(process.argv[7] ?? String(logs.transcript.length - 5), 10), logs.transcript.length - 1),
);
const logsStrip = {
  mode: "logs",
  data: { rows: logs.transcript.slice(logsChatOffset), chatHasPrevious: true, chatHasNext: false, eventHasPrevious: true, eventHasNext: false },
};
const panels = composeStrip(mode === "cmd" ? cmdStrip : mode === "logs" ? logsStrip : gridStrip);

const KEY = 120;
const GAP = 10;
const width = KEY * 4 + GAP * 5;
const height = GAP + KEY * 2 + GAP + 100 + GAP;
const canvas = createCanvas(width, height);
const ctx = canvas.getContext("2d");
ctx.fillStyle = "#17181c";
ctx.fillRect(0, 0, width, height);

/**
 * Logs mode paints event keys, not agent keys — mirroring `descriptorEvents` in
 * surface.ts, including the LIVE key wearing the focused agent's own face. The
 * preview used to draw the agent grid in every mode, so the one surface this
 * script is most often used to check was the one it could not show.
 */
const logsKeyDescriptors = () => {
  const offset = Math.max(0, logs.event_keys.length - 8);
  // Defaults to LIVE, which is what the surface opens on. Pass a key slot
  // (0-7) as the sixth argument to preview an event key being the active one
  // instead — the selection contract is mutually exclusive, so the two states
  // are only checkable side by side.
  const selectedSlot = Number.parseInt(process.argv[6] ?? "7", 10);
  const selected = offset + Math.max(0, Math.min(7, selectedSlot));
  return layoutPhysicalKeys(
    logs.event_keys.slice(offset, offset + 8).map((event, index) => {
      const position = offset + index;
      if (event.kind === "live") {
        return { ...agents[0], title: "LIVE", role: "live", subLabel: "AGENT", timeLabel: "", selected: position === selected };
      }
      return {
        identifier: `event-${position}`,
        title: event.text,
        vendor: "logs",
        role: "event",
        subLabel: event.badge,
        timeLabel: event.time,
        selected: position === selected,
        bucket: "queued",
        progress_percent: null,
        priority: false,
        dependency_ready: true,
      };
    }),
  );
};

const descriptors = mode === "logs" ? logsKeyDescriptors() : layoutKeys(agents, columnOffset);
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
