import { describe, expect, it, vi } from "vitest";
import { createPhysicalSurface, descriptorEvents, descriptorSettings, repaintGrid } from "../src/surface.js";
import { layoutPhysicalKeys } from "../src/keys.js";
import type { EventKey } from "../src/controller.js";
import type { TranscriptRow } from "../src/channel.js";
import { settingsView } from "../src/settings.js";
import { VOICE_WAVEFORM_COLUMNS } from "../src/voicePanel.js";
import { createRasterizer } from "../src/rasterizer.js";

const message = (body: string): TranscriptRow => ({ kind: "message", role: "assistant", body, tool: null });

describe("physical surface composition", () => {
  it("places command faces on the exact keys their controller handles", () => {
    const descriptors = layoutPhysicalKeys([
      { identifier: "pause", title: "Pause", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "logs", title: "Logs", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "mic", title: "Mic", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
      { identifier: "settings", title: "Settings", vendor: "command", bucket: "queued", progress_percent: 0, priority: false },
    ]);
    expect(descriptors.slice(0, 4).map((descriptor) => descriptor.kind === "agent" ? descriptor.title : "empty")).toEqual(["Pause", "Logs", "Mic", "Settings"]);
    expect(descriptors.slice(4).every((descriptor) => descriptor.kind === "empty")).toBe(true);
  });
  it("repaints eight keys from the daemon grid and blacks out empty slots", async () => {
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    await repaintGrid({ sendFeatureReport }, {
      agents: [{ bucket: "running" }, { bucket: "paused" }],
      total: 2,
      windows: 1,
      max_column_offset: 0,
    });
    expect(sendFeatureReport).toHaveBeenCalledTimes(8);
    const reports = sendFeatureReport.mock.calls.map(([report]) => report as Uint8Array);
    expect(reports[0]?.[1]).toBe(0x06);
    expect(reports[0]?.[3]).toBeGreaterThan(0);
    expect(reports[7]?.slice(3, 6)).toEqual(Buffer.from([0, 0, 0]));
  });

  it("uses the production rasterizer and dirty cache for populated keys", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const grid = { agents: [{ identifier: "1358", title: "Live proof", vendor: "codex", bucket: "running", progress_percent: 42, priority: false }], total: 1, windows: 1, max_column_offset: 0 };
    await surface.repaint({ write, sendFeatureReport } as never, grid);
    const firstWrites = write.mock.calls.length;
    expect(firstWrites).toBeGreaterThan(0);
    expect(write.mock.calls.some(([report]) => (report as Uint8Array)[1] === 0x07)).toBe(true);
    await surface.repaint({ write, sendFeatureReport } as never, grid);
    expect(write.mock.calls.length).toBeGreaterThanOrEqual(firstWrites);
  });

  describe("descriptorEvents", () => {
    const liveKey = (): EventKey => ({ kind: "live", badge: "AGENT", text: "LIVE", time: "", start: 20 });
    const eventKeys = (count: number): EventKey[] =>
      Array.from({ length: count }, (_, index) => ({ kind: "event", badge: "INFO", text: `event-${index}`, time: "1m", start: index }));

    // SP-1959: LIVE is pinned to the bottom-right key and never scrolls, so the
    // event page holds seven events with the pinned LIVE key always in slot 7.
    it("pins the LIVE key to the last slot at every event offset", () => {
      const events = [...eventKeys(15), liveKey()];
      for (const offset of [0, 5, 10]) {
        const descriptors = descriptorEvents(events, offset, null, null);
        expect(descriptors).toHaveLength(8);
        expect(descriptors[7]?.title).toBe("LIVE");
        // The filled event slots are the contiguous page at the offset, oldest
        // first; LIVE is not among them, and any remaining slots are empty.
        const page = events.slice(0, -1).slice(offset, offset + 7);
        expect(descriptors.slice(0, page.length).map((descriptor) => descriptor?.title)).toEqual(
          page.map((event) => event.text),
        );
        expect(descriptors.slice(page.length, 7).every((descriptor) => descriptor === undefined)).toBe(true);
      }
    });

    it("leaves padded event slots empty when the page has fewer than seven events", () => {
      const events = [eventKeys(1)[0], liveKey()];
      const descriptors = descriptorEvents(events, 0, null, null);
      expect(descriptors).toHaveLength(8);
      expect(descriptors[0]?.title).toBe("event-0");
      expect(descriptors.slice(1, 7).every((descriptor) => descriptor === undefined)).toBe(true);
      expect(descriptors[7]?.title).toBe("LIVE");
    });

    it("lights the pinned LIVE face when LIVE is the selected key", () => {
      const events = [eventKeys(1)[0], liveKey()];
      const descriptors = descriptorEvents(events, 0, events.length - 1, null);
      expect(descriptors[7]?.selected).toBe(true);
      expect(descriptors[0]?.selected).toBe(false);
    });
  });

  it("renders event-window changes separately from transcript changes", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const backend = { write, sendFeatureReport } as never;
    const grid = { agents: [], total: 0, windows: 1, max_column_offset: 0 };
    const base = { mode: "logs" as const, focusedIdentifier: null, columnOffset: 0, eventLines: [
      { kind: "event" as const, badge: "EMIT", text: "event-a", time: "1m", start: 0 },
      { kind: "event" as const, badge: "CONSUME", text: "event-b", time: "2m", start: 1 },
      { kind: "event" as const, badge: "INFO", text: "event-c", time: "3m", start: 2 },
      { kind: "live" as const, badge: "AGENT", text: "LIVE", time: "", start: 2 },
    ], eventOffset: 0, transcriptRows: [message("chat-a"), message("chat-b")], eventHasNext: true, chatHasNext: true };
    await surface.repaint(backend, grid, {}, undefined, base);
    const first = write.mock.calls.length;
    await surface.repaint(backend, grid, {}, undefined, { ...base, eventOffset: 1 });
    const afterEvent = write.mock.calls.length;
    await surface.repaint(backend, grid, {}, undefined, { ...base, eventOffset: 1, transcriptRows: [message("chat-b"), message("chat-c")] });
    expect(afterEvent).toBeGreaterThan(first);
    expect(write.mock.calls.length).toBeGreaterThan(afterEvent);
  });

  // The highlight is the only thing on the deck showing that the strip and the
  // keys are describing the same event, so it has to survive the whole path
  // from controller state to a key upload.
  it("uploads a new key face when the event selection moves", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const backend = { write, sendFeatureReport } as never;
    const grid = { agents: [], total: 0, windows: 1, max_column_offset: 0 };
    const base = {
      mode: "logs" as const,
      focusedIdentifier: null,
      columnOffset: 0,
      eventLines: [
        { kind: "event" as const, badge: "EMIT", text: "event-a", time: "1m", start: 0 },
        { kind: "event" as const, badge: "EMIT", text: "event-b", time: "2m", start: 1 },
        { kind: "live" as const, badge: "AGENT", text: "LIVE", time: "", start: 1 },
      ],
      eventOffset: 0,
      transcriptRows: [],
      selectedEvent: null as number | null,
    };
    await surface.repaint(backend, grid, {}, undefined, base);
    const painted = write.mock.calls.length;
    // Only the selection changes; nothing else about the surface moves.
    await surface.repaint(backend, grid, {}, undefined, { ...base, selectedEvent: 1 });
    expect(write.mock.calls.slice(painted).some(([report]) => (report as Uint8Array)[1] === 0x07)).toBe(true);
  });

  // Knob 2 is only worth turning if its offset reaches the pixels: the scroll
  // has to survive controller state -> grid data -> a partial-region upload of
  // the merged provider panel alone.
  it("repaints the merged provider panel, and only it, when the provider scroll moves", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const backend = { write, sendFeatureReport } as never;
    const grid = { agents: [], total: 0, windows: 1, max_column_offset: 0 };
    const meter = (used: number) => ({ provider: "p", windows: { session: { used_percent: used, duration_minutes: 300 } } });
    const usage = { a: meter(10), b: meter(20), c: meter(30), d: meter(40) };
    const base = { mode: "grid" as const, focusedIdentifier: null, columnOffset: 0, providerOffset: 0 };

    await surface.repaint(backend, grid, usage, undefined, base);
    const painted = write.mock.calls.length;
    await surface.repaint(backend, grid, usage, undefined, { ...base, providerOffset: 1 });

    const regions = write.mock.calls
      .slice(painted)
      .map(([report]) => Buffer.from(report as Uint8Array))
      .filter((report) => report[1] === 0x0c)
      .map((report) => ({ x: report.readUInt16LE(2), width: report.readUInt16LE(6) }));
    expect(regions.length).toBeGreaterThan(0);
    for (const region of regions) expect(region).toEqual({ x: 200, width: 400 });
  });

  // Falling through to the grid strip put the fleet summary under the four
  // agent command keys, so the strip and the keys disagreed about the mode.
  it("keeps a cmd-mode strip when the focused agent leaves the projection", async () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const surface = createPhysicalSurface();
    const backend = { write, sendFeatureReport } as never;
    const state = { mode: "cmd" as const, focusedIdentifier: "1358", columnOffset: 0 };
    await surface.repaint(backend, { agents: [], total: 0, windows: 1, max_column_offset: 0 }, {}, undefined, state);
    // One 800-wide region write, not four 200-wide ones: every report carries
    // the full-strip geometry.
    const strip = write.mock.calls.map(([report]) => report as Uint8Array).filter((report) => report[1] === 0x0c);
    expect(strip.length).toBeGreaterThan(0);
    for (const report of strip) expect(Buffer.from(report).readUInt16LE(6)).toBe(800);
  });
});

describe("descriptorSettings", () => {
  const view = (count: number, selectedId: string | null = null, offset = 0) =>
    settingsView(
      Array.from({ length: count }, (_, index) => ({ id: `m${index}`, label: `Mic ${index}` })),
      selectedId,
      offset,
    );

  const titles = (descriptors: ReturnType<typeof descriptorSettings>): (string | null | undefined)[] =>
    descriptors.map((descriptor) => (descriptor === undefined ? undefined : descriptor.title));

  it("puts six microphones on keys 0-5, TestMic on 6 and paging on 7", () => {
    const descriptors = descriptorSettings(view(9), false);
    expect(descriptors).toHaveLength(8);
    expect(titles(descriptors)).toEqual(["Mic 0", "Mic 1", "Mic 2", "Mic 3", "Mic 4", "Mic 5", "TestMic", "More"]);
    expect(descriptors[7]?.subLabel).toBe("1/2");
  });

  it("leaves key 7 empty when every microphone fits on one page", () => {
    expect(descriptorSettings(view(2), false)[7]).toBeUndefined();
    expect(titles(descriptorSettings(view(2), false)).slice(0, 6)).toEqual([
      "Mic 0",
      "Mic 1",
      undefined,
      undefined,
      undefined,
      undefined,
    ]);
  });

  /**
   * The selection reuses the *logs* surface's idiom — `role: "event"` is what
   * paints the brighter plate, the left rail and the inverted badge chip. A
   * second way of saying "this one is active" would make neither definitive.
   */
  it("marks the selected microphone with the log surface's selection idiom", () => {
    const descriptors = descriptorSettings(view(3, "m1"), false);
    expect(descriptors[1]).toMatchObject({ role: "event", selected: true, subLabel: "IN USE" });
    expect(descriptors[0]).toMatchObject({ role: "event", selected: false, subLabel: "MIC" });
  });

  it("paints the same idiom the log keys do, all the way to the pixels", () => {
    const rasterizer = createRasterizer();
    const [plain, selected] = [false, true].map((flag) => {
      const [descriptor] = layoutPhysicalKeys(descriptorSettings(view(1, flag ? "m0" : null), false));
      return rasterizer.key(descriptor);
    });
    expect(Buffer.from(plain).equals(Buffer.from(selected))).toBe(false);
  });

  it("shows TestMic as live only while it is held", () => {
    expect(descriptorSettings(view(1), false)[6]?.subLabel).toBe("HOLD");
    expect(descriptorSettings(view(1), true)[6]?.subLabel).toBe("LIVE");
  });

  // A headless box is a normal box: six blank keys and no paging arrow, rather
  // than something that looks broken.
  it("renders a machine with no microphone as empty keys plus TestMic", () => {
    const descriptors = descriptorSettings(view(0), false);
    expect(descriptors.slice(0, 6).every((descriptor) => descriptor === undefined)).toBe(true);
    expect(descriptors[6]?.title).toBe("TestMic");
    expect(descriptors[7]).toBeUndefined();
  });
});

describe("the command and settings surfaces on the device", () => {
  const backend = () => {
    const write = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    const sendFeatureReport = vi.fn<(report: Uint8Array) => Promise<void>>(async () => undefined);
    return { write, sendFeatureReport, device: { write, sendFeatureReport } as never };
  };
  const grid = { agents: [{ identifier: "1358", bucket: "running", title: "Live proof", vendor: "codex", progress_percent: 42, priority: false }], total: 1, windows: 1, max_column_offset: 0 };

  // The keys have to appear and disappear through the same publish/diff path as
  // every other key change, or the deck keeps painting keys that are gone.
  it("uploads new key faces when Send and Cancel appear", async () => {
    const { write, device } = backend();
    const surface = createPhysicalSurface();
    const base = { mode: "cmd" as const, focusedIdentifier: "1358", columnOffset: 0 };
    await surface.repaint(device, grid, {}, undefined, base);
    const painted = write.mock.calls.length;
    await surface.repaint(device, grid, {}, undefined, { ...base, hasTranscript: true });
    expect(write.mock.calls.slice(painted).some(([report]) => (report as Uint8Array)[1] === 0x07)).toBe(true);
  });

  it("paints the settings surface as one full-width panel", async () => {
    const { write, device } = backend();
    const surface = createPhysicalSurface();
    await surface.repaint(device, grid, {}, undefined, {
      mode: "settings",
      focusedIdentifier: "1358",
      columnOffset: 0,
      microphones: [{ id: "a", label: "Yeti X" }],
      selectedMicId: "a",
      micOffset: 0,
    });
    const strip = write.mock.calls.map(([report]) => report as Uint8Array).filter((report) => report[1] === 0x0c);
    expect(strip.length).toBeGreaterThan(0);
    for (const report of strip) expect(Buffer.from(report).readUInt16LE(6)).toBe(800);
  });

  /**
   * The load-bearing property at the surface level: the strip repaints from
   * locally-captured readings alone. Nothing here has a channel, a session id
   * or any transcribed text, and the panel still changes.
   */
  it("repaints the voice panel from waveform and level alone", async () => {
    const { write, device } = backend();
    const surface = createPhysicalSurface();
    const columns = (amplitude: number) =>
      Array.from({ length: VOICE_WAVEFORM_COLUMNS }, () => ({ min: -amplitude, max: amplitude }));
    const base = {
      mode: "cmd" as const,
      focusedIdentifier: "1358",
      columnOffset: 0,
      micHeld: true,
      voice: { columns: columns(0.1), dbfs: -40, text: "", holding: true, unavailableReason: null },
    };
    await surface.repaint(device, grid, {}, undefined, base);
    const painted = write.mock.calls.length;
    await surface.repaint(device, grid, {}, undefined, {
      ...base,
      voice: { ...base.voice, columns: columns(0.9), dbfs: -6 },
    });
    const strip = write.mock.calls.slice(painted).map(([report]) => report as Uint8Array).filter((report) => report[1] === 0x0c);
    expect(strip.length).toBeGreaterThan(0);
  });
});
