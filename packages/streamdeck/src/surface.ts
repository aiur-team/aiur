import type { HidBackend } from "./backend.js";
import { BLACK, buildKeyFillReport, DEFAULT_FILL_INDEX_BASE, type RgbColor } from "./keys/keyFill.js";
import { layoutKeys, layoutPhysicalKeys, type AgentInput, type KeyDescriptor } from "./keys.js";
import { KeyRenderer } from "./keys/keyRenderer.js";
import { KeyWriteQueue } from "./keys/writeQueue.js";
import { createKeyReportWriter } from "./keys/keyWriter.js";
import type { Runtime } from "./runtime.js";
import { createRasterizer } from "./rasterizer.js";
import { StripRenderer } from "./touchStrip/stripRenderer.js";
import { summaryModel } from "./touchStrip/summarySegment.js";
import { providerRows } from "./touchStrip/providerPanel.js";
import { agentDetailModel } from "./touchStrip/agentDetail.js";
import { pagerModel } from "./touchStrip/pagerSegment.js";
import { currentWindow } from "./dial.js";
import type { EventKey } from "./controller.js";
import type { StripData } from "./touchStrip/stripLayout.js";
import type { StreamDeckGrid, TranscriptRow } from "./channel.js";

export type PhysicalMode = "grid" | "cmd" | "logs";
export interface PhysicalSurfaceState {
  readonly mode: PhysicalMode;
  readonly focusedIdentifier: string | null;
  readonly micHeld?: boolean;
  readonly columnOffset: number;
  /** First provider row the merged provider panel shows; knob 2 moves it. */
  readonly providerOffset?: number;
  readonly transcriptRows?: readonly TranscriptRow[];
  readonly eventLines?: readonly EventKey[];
  readonly eventOffset?: number;
  readonly eventHasPrevious?: boolean;
  readonly eventHasNext?: boolean;
  readonly chatHasPrevious?: boolean;
  readonly chatHasNext?: boolean;
  /**
   * Position in `eventLines` the strip is currently reading, or null. Drives
   * the highlight on the event key, in both directions: a press sets it, and so
   * does scrolling the transcript past that event's header.
   */
  readonly selectedEvent?: number | null;
}

const faceColours: Readonly<Record<string, RgbColor>> = {
  running: { r: 25, g: 85, b: 55 },
  paused: { r: 100, g: 65, b: 20 },
  retrying: { r: 95, g: 25, b: 25 },
  queued: { r: 35, g: 45, b: 80 },
  idle: { r: 35, g: 45, b: 80 },
};

const colourFor = (agent: Readonly<Record<string, unknown>> | undefined): RgbColor => faceColours[typeof agent?.bucket === "string" ? agent.bucket : ""] ?? BLACK;

const descriptorAgents = (grid: StreamDeckGrid): AgentInput[] => grid.agents.map((agent) => ({
  identifier: String(agent.identifier ?? ""),
  title: typeof agent.title === "string" ? agent.title : "",
  vendor: typeof agent.vendor === "string" ? agent.vendor : "unknown",
  icon: typeof agent.icon === "string" ? agent.icon : "",
  bucket: (typeof agent.bucket === "string" ? agent.bucket : "queued") as AgentInput["bucket"],
  progress_percent: typeof agent.progress_percent === "number" ? agent.progress_percent : 0,
  priority: agent.priority === true,
  dependency_ready: agent.dependency_ready === true,
}));

const descriptorEvents = (events: readonly EventKey[], offset: number, selected: number | null): AgentInput[] =>
  events.slice(offset, offset + 8).map((event, index) => ({
    identifier: `event-${offset + index}`,
    title: event.text,
    vendor: "logs",
    // The feed's first row is a live indicator, not an event, and the mock
    // paints it as its own distinct key.
    role: event.kind === "live" ? ("live" as const) : ("event" as const),
    subLabel: event.badge,
    timeLabel: event.time,
    selected: offset + index === selected,
    bucket: "queued" as const,
    progress_percent: 0,
    priority: false,
    dependency_ready: true,
  }));

/**
 * The four per-agent command keys, in the order the mock defines: pause/play,
 * prioritise/deprioritise, logs, and the hold-to-talk mic. Each carries its own
 * glyph and caption; the mic's caption is what tells the renderer to paint the
 * held state.
 */
const descriptorCommands = (agent: Readonly<Record<string, unknown>> | null | undefined, micHeld: boolean): (AgentInput | undefined)[] => {
  const identifier = String(agent?.identifier ?? "focused");
  // Only a paused agent offers Resume. Keying this off `bucket === "running"`
  // instead made every alert/stuck/queued agent show a Resume key that the
  // controller then had no action for, so pressing it did nothing at all.
  const paused = agent?.bucket === "paused";
  const prioritised = agent?.priority === true;
  const command = (name: string, title: string, icon: string, subLabel: string): AgentInput => ({
    identifier: `${identifier}:${name}`,
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
  const commands: AgentInput[] = [
    command("pause", paused ? "Resume" : "Pause", paused ? "play" : "pause", paused ? "RESUME" : "HOLD"),
    command("priority", prioritised ? "Deprioritize" : "Prioritize", prioritised ? "down" : "up", prioritised ? "LOWER" : "RAISE"),
    command("logs", "Logs", "logs", "OPEN"),
    command("mic", "Mic", "mic", micHeld ? "LIVE" : "HOLD"),
  ];
  return [...commands, undefined, undefined, undefined, undefined];
};

/**
 * Minimal production compositor for the direct-HID path. Empty keys use the
 * existing feature-report fast path; populated keys use the same status colour
 * contract while the pixel encoder remains an injected future boundary.
 *
 * Keeping this boundary explicit is important: it makes daemon-to-device
 * repaint real without smuggling a second projection or a fake JPEG into the
 * transport layer.
 */
export const repaintGrid = async (backend: Pick<HidBackend, "sendFeatureReport">, grid: StreamDeckGrid): Promise<void> => {
  const agents = grid.agents.slice(0, 8);
  for (let index = 0; index < 8; index += 1) {
    await backend.sendFeatureReport(buildKeyFillReport(index, colourFor(agents[index]), DEFAULT_FILL_INDEX_BASE).data);
  }
};

/** Stateful key compositor; unchanged descriptors do not reach the wire. */
export const createPhysicalSurface = () => {
  const rasterizer = createRasterizer();
  const renderer = new KeyRenderer((descriptor: KeyDescriptor) =>
    descriptor.kind === "empty" ? { kind: "fill", color: BLACK } : { kind: "image", jpeg: rasterizer.key(descriptor) },
  );
  const stripRenderer = new StripRenderer((content, region) => rasterizer.segment(content, region.width));
  let keyQueue: KeyWriteQueue | null = null;
  let queueBackend: HidBackend | null = null;
  let lastSignature: string | null = null;
  return {
    repaint: async (backend: HidBackend, grid: StreamDeckGrid, usage: Readonly<Record<string, unknown>> = {}, runtime?: Pick<Runtime, "notifyWriteFailure">, state: PhysicalSurfaceState = { mode: "grid", focusedIdentifier: null, columnOffset: 0 }): Promise<void> => {
      if (queueBackend !== backend) {
        queueBackend = backend;
        lastSignature = null;
        renderer.invalidate();
        stripRenderer.invalidate();
        keyQueue = new KeyWriteQueue(createKeyReportWriter(backend, runtime ?? { notifyWriteFailure: () => undefined }));
      }
      // Bucketed by the minute for the same reason the rasterizer's cache is:
      // the strip renders relative times, so identical inputs can still owe the
      // device new pixels once a minute. The panel-level byte diff still filters
      // the panels whose labels did not actually change, so this costs a
      // re-encode, not a write.
      const signature = JSON.stringify({ grid, usage, state, minute: Math.floor(Date.now() / 60_000) });
      if (signature === lastSignature) return;
      lastSignature = signature;
      const focused = state.focusedIdentifier === null ? null : grid.agents.find((agent) => String(agent.identifier) === state.focusedIdentifier);
      // Events fill the keys in reading order. `layoutKeys` is column-major,
      // which is right for the agent grid (paging moves through columns) but
      // would interleave a sequential event window across the two rows.
      const visibleGrid = state.mode === "logs"
        ? layoutPhysicalKeys(descriptorEvents(state.eventLines ?? [], state.eventOffset ?? 0, state.selectedEvent ?? null))
        : state.mode === "cmd"
        ? layoutPhysicalKeys(descriptorCommands(focused, state.micHeld === true))
        : layoutKeys(descriptorAgents(grid), state.columnOffset);
      const paints = renderer.render(visibleGrid);
      for (const paint of paints) {
        await keyQueue?.enqueue(paint);
      }
      // A cmd-mode strip is built even when the focused agent has left the
      // projection — merged, or paged out. Falling through to the grid strip
      // put the fleet summary under the four agent command keys, so the strip
      // and the keys disagreed about which mode the deck was in. With only the
      // identifier, the panel shows the ticket and an unknown status, which is
      // the truth.
      const strip: StripData = state.mode === "cmd" ? {
        mode: "cmd",
        data: { detail: agentDetailModel(focused ?? { identifier: state.focusedIdentifier }) },
      } : state.mode === "logs" ? {
        mode: "logs",
        data: {
          rows: state.transcriptRows ?? [],
          chatHasPrevious: state.chatHasPrevious,
          chatHasNext: state.chatHasNext,
          eventHasPrevious: state.eventHasPrevious,
          eventHasNext: state.eventHasNext,
        },
      } : {
        mode: "grid",
        data: {
          // `build` comes straight from the projection when present. Omitting
          // it left the summary segment permanently reading "No build order"
          // even while a build order was running.
          summary: summaryModel(
            grid.agents.filter((agent) => agent.bucket === "running").length,
            grid.total - grid.agents.filter((agent) => agent.bucket === "running").length,
            (grid as { build?: unknown }).build as Parameters<typeof summaryModel>[2],
          ),
          // One row per provider family the daemon reported, not two fixed
          // slots: a fleet with a third configured provider had a real meter
          // that no pixel on the deck could show.
          providers: providerRows(usage),
          // The panel clamps this itself, so a provider dropping out of the
          // daemon's map cannot leave the strip parked past the last row.
          providerOffset: state.providerOffset ?? 0,
          // `currentWindow` is the tested pager maths dial D itself uses. A
          // plain columnOffset/4 disagrees with it whenever the last window is
          // clamped by maxColumnOffset, lighting the wrong dot after a page.
          pager: pagerModel(grid.total, 8, currentWindow(state.columnOffset, grid.total)),
          pagerLabel: `${grid.total} Agents`,
        },
      };
      try {
        for (const paint of stripRenderer.render(strip)) {
          for (const report of paint.reports) await backend.write(report);
        }
      } catch (error) {
        runtime?.notifyWriteFailure(error);
        throw error;
      }
    },
  };
};
