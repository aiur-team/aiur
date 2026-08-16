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
import { providerSegmentModel, type ProviderMeter } from "./touchStrip/providerSegment.js";
import { pagerModel } from "./touchStrip/pagerSegment.js";
import type { StripData } from "./touchStrip/stripLayout.js";
import type { ChatLine } from "./touchStrip/stripLayout.js";
import type { StreamDeckGrid } from "./channel.js";

export type PhysicalMode = "grid" | "cmd" | "logs";
export interface PhysicalSurfaceState {
  readonly mode: PhysicalMode;
  readonly focusedIdentifier: string | null;
  readonly micHeld?: boolean;
  readonly columnOffset: number;
  readonly transcriptLines?: readonly ChatLine[];
  readonly eventLines?: readonly string[];
  readonly eventOffset?: number;
  readonly eventHasPrevious?: boolean;
  readonly eventHasNext?: boolean;
  readonly chatHasPrevious?: boolean;
  readonly chatHasNext?: boolean;
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
  bucket: (typeof agent.bucket === "string" ? agent.bucket : "queued") as AgentInput["bucket"],
  progress_percent: typeof agent.progress_percent === "number" ? agent.progress_percent : 0,
  priority: agent.priority === true,
  dependency_ready: agent.dependency_ready === true,
}));

const descriptorEvents = (lines: readonly string[], offset: number): AgentInput[] => lines.slice(offset, offset + 8).map((line, index) => ({
  identifier: `event-${offset + index}`,
  title: line,
  vendor: "logs",
  bucket: "queued",
  progress_percent: 0,
  priority: false,
  dependency_ready: true,
}));

const descriptorCommands = (agent: Readonly<Record<string, unknown>> | null | undefined, micHeld: boolean): (AgentInput | undefined)[] => {
  const identifier = String(agent?.identifier ?? "focused");
  const running = agent?.bucket === "running";
  const commands: AgentInput[] = [
    { identifier: `${identifier}:pause`, title: running ? "Pause" : "Resume", vendor: "command", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
    { identifier: `${identifier}:priority`, title: agent?.priority === true ? "Deprioritize" : "Prioritize", vendor: "command", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
    { identifier: `${identifier}:logs`, title: "Logs", vendor: "command", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
    { identifier: `${identifier}:mic`, title: micHeld ? "Mic (LIVE)" : "Mic", vendor: "command", bucket: "queued", progress_percent: 0, priority: false, dependency_ready: true },
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
  const stripRenderer = new StripRenderer((content) => rasterizer.segment(content));
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
      const signature = JSON.stringify({ grid, usage, state });
      if (signature === lastSignature) return;
      lastSignature = signature;
      const focused = state.focusedIdentifier === null ? null : grid.agents.find((agent) => String(agent.identifier) === state.focusedIdentifier);
      const visibleGrid = state.mode === "logs"
        ? layoutKeys(descriptorEvents(state.eventLines ?? [], state.eventOffset ?? 0), 0)
        : state.mode === "cmd"
        ? layoutPhysicalKeys(descriptorCommands(focused, state.micHeld === true))
        : layoutKeys(descriptorAgents(grid), state.columnOffset);
      const paints = renderer.render(visibleGrid);
      for (const paint of paints) {
        await keyQueue?.enqueue(paint);
      }
      const strip: StripData = state.mode === "cmd" && focused !== undefined && focused !== null ? {
        mode: "cmd",
        data: { identity: String(focused.identifier), status: String(focused.bucket ?? "unknown"), percent: Number(focused.progress_percent ?? 0), ticketId: String(focused.identifier) },
      } : state.mode === "logs" ? {
        mode: "logs",
        data: {
          lines: state.transcriptLines ?? [],
          chatHasPrevious: state.chatHasPrevious,
          chatHasNext: state.chatHasNext,
          eventHasPrevious: state.eventHasPrevious,
          eventHasNext: state.eventHasNext,
        },
      } : {
        mode: "grid",
        data: {
          summary: summaryModel(grid.agents.filter((agent) => agent.bucket === "running").length, grid.total - grid.agents.filter((agent) => agent.bucket === "running").length),
          claude: providerSegmentModel((usage.claude ?? null) as ProviderMeter | null),
          codex: providerSegmentModel((usage.codex ?? null) as ProviderMeter | null),
          pager: pagerModel(grid.total, 8, Math.floor(state.columnOffset / 4)),
          pagerLabel: `${grid.total} agents`,
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
