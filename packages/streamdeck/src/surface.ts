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
import { currentWindow, EVENTS_PER_PAGE } from "./dial.js";
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

/**
 * One agent's grid descriptor.
 *
 * `progress_percent` is passed through unchanged, including `null`. Defaulting
 * it to `0` here is what let a missing reading paint as a real "0% done" bar,
 * and the deck has no other way to tell the two apart once the value is a
 * number. `runtime_seconds` two functions below has always projected absence as
 * absence; progress now agrees with it.
 */
const agentDescriptor = (agent: Readonly<Record<string, unknown>>): AgentInput => ({
  identifier: String(agent.identifier ?? ""),
  title: typeof agent.title === "string" ? agent.title : "",
  vendor: typeof agent.vendor === "string" ? agent.vendor : "unknown",
  icon: typeof agent.icon === "string" ? agent.icon : "",
  bucket: (typeof agent.bucket === "string" ? agent.bucket : "queued") as AgentInput["bucket"],
  progress_percent: typeof agent.progress_percent === "number" ? agent.progress_percent : null,
  progress_freshness: typeof agent.progress_freshness === "string" ? agent.progress_freshness : null,
  priority: agent.priority === true,
  dependency_ready: agent.dependency_ready === true,
});

const descriptorAgents = (grid: StreamDeckGrid): AgentInput[] => grid.agents.map(agentDescriptor);

/**
 * The eight log keys: EVENTS_PER_PAGE event slots plus the LIVE key pinned to
 * the bottom-right slot.
 *
 * LIVE never participates in the scroll window, so the event page is sliced for
 * EVENTS_PER_PAGE (seven) events and the pinned LIVE key is appended after it —
 * it stays on the last key at every scroll position instead of being pushed off
 * by paging.
 *
 * The LIVE key is given the focused agent's own face — ticket number, lane
 * icon, provider mark and progress bar — with `LIVE` in the title slot. It is
 * the only key on this surface that describes the agent rather than something
 * the agent did, so dressing it as an event key made the one key that answers
 * "how far along is this ticket?" the one key that did not say.
 */
export const descriptorEvents = (
  events: readonly EventKey[],
  offset: number,
  selected: number | null,
  focused: Readonly<Record<string, unknown>> | null | undefined,
): (AgentInput | undefined)[] => {
  if (events.length === 0) return [];
  const live = events[events.length - 1];

  // The event page is sliced from the events only — LIVE is pinned and is not a
  // page member, so it is excluded from the slice and appended once, keeping it
  // out of the seven event slots no matter the offset.
  const slots: (AgentInput | undefined)[] = events
    .slice(0, -1)
    .slice(offset, offset + EVENTS_PER_PAGE)
    .map((event, index) => {
      const position = offset + index;
      return {
        identifier: `event-${position}`,
        title: event.text,
        vendor: "logs",
        role: "event" as const,
        subLabel: event.badge,
        timeLabel: event.time,
        selected: position === selected,
        bucket: "queued" as const,
        progress_percent: null,
        priority: false,
        dependency_ready: true,
      };
    });
  while (slots.length < EVENTS_PER_PAGE) slots.push(undefined);

  const agent = focused === null || focused === undefined ? null : agentDescriptor(focused);
  slots.push({
    ...(agent ?? {
      identifier: "",
      title: "",
      vendor: "unknown",
      icon: "",
      bucket: "queued" as const,
      progress_percent: null,
      priority: false,
      dependency_ready: true,
    }),
    title: "LIVE",
    role: "live" as const,
    subLabel: live.badge,
    timeLabel: "",
    selected: events.length - 1 === selected,
  });
  return slots;
};

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
    progress_percent: null,
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
        ? layoutPhysicalKeys(descriptorEvents(state.eventLines ?? [], state.eventOffset ?? 0, state.selectedEvent ?? null, focused))
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
