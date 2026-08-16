import { describe, expect, it } from "vitest";

import { STRIP_WIDTH } from "../../src/touchStrip/geometry.js";
import { pagerModel } from "../../src/touchStrip/pagerSegment.js";
import { providerSegmentModel } from "../../src/touchStrip/providerSegment.js";
import { summaryModel } from "../../src/touchStrip/summarySegment.js";
import { composeStrip, type SettingsData, type StripPanel } from "../../src/touchStrip/stripLayout.js";
import { agentDetailModel } from "../../src/touchStrip/agentDetail.js";
import type { ProviderPanelRow } from "../../src/touchStrip/providerPanel.js";
import type { TranscriptRow } from "../../src/channel.js";
import { voicePanel, type VoicePanelData } from "../../src/voicePanel.js";

const message = (body: string): TranscriptRow => ({ kind: "message", role: "assistant", body, tool: null });

const voice = (over: { holding?: boolean; text?: string } = {}): VoicePanelData =>
  voicePanel({ columns: [], dbfs: -20, text: over.text ?? "", holding: over.holding ?? false, unavailableReason: null });

const settings = (over: Partial<SettingsData> = {}) =>
  composeStrip({ mode: "settings", data: { selectedLabel: "Yeti X", deviceCount: 3, pageLabel: "1/1", ...over } });

const provider = (label: string, usedPercent = 10): ProviderPanelRow => ({
  label,
  model: providerSegmentModel({ provider: label, windows: { session: { used_percent: usedPercent, duration_minutes: 300 } } }),
});

const grid = (providers: readonly ProviderPanelRow[], providerOffset = 0) =>
  composeStrip({
    mode: "grid",
    data: {
      summary: summaryModel(2, 3),
      providers,
      providerOffset,
      pager: pagerModel(9, 4, 1),
      pagerLabel: "5-8",
    },
  });

const providerLabels = (panel: StripPanel): readonly string[] =>
  panel.content.kind === "providers" ? panel.content.model.rows.map((row) => row.label) : [];

/** Panels must tile the strip exactly: no gap, no overlap, no overrun. */
const tilesTheStrip = (panels: readonly StripPanel[]): boolean =>
  panels.reduce((next, panel) => (next === panel.region.x ? next + panel.region.width : Number.NaN), 0) === STRIP_WIDTH;

describe("composeStrip", () => {
  it("tiles the whole strip in every mode", () => {
    expect(tilesTheStrip(grid([provider("claude"), provider("codex")]))).toBe(true);
    expect(tilesTheStrip(grid([provider("claude"), provider("codex"), provider("kimi")]))).toBe(true);
    expect(tilesTheStrip(grid([]))).toBe(true);
    expect(tilesTheStrip(composeStrip({ mode: "cmd", data: { detail: agentDetailModel({ identifier: "1356" }) } }))).toBe(true);
    expect(tilesTheStrip(composeStrip({ mode: "logs", data: { rows: [message("a")] } }))).toBe(true);
    expect(tilesTheStrip(settings())).toBe(true);
    expect(tilesTheStrip(settings({ voice: voice({ holding: true }) }))).toBe(true);
    expect(
      tilesTheStrip(
        composeStrip({
          mode: "cmd",
          data: { detail: agentDetailModel({ identifier: "1356" }), voice: voice({ holding: true }) },
        }),
      ),
    ).toBe(true);
  });

  it("grid mode with two providers keeps the four 200-wide segments", () => {
    const panels = grid([provider("claude"), provider("codex")]);
    expect(panels.map((panel) => panel.region.width)).toEqual([200, 200, 200, 200]);
    expect(panels[0].content.kind).toBe("summary");
    expect(panels[1].content).toMatchObject({ kind: "provider", row: { label: "claude" } });
    expect(panels[2].content).toMatchObject({ kind: "provider", row: { label: "codex" } });
    expect(panels[3].content).toMatchObject({ kind: "pager", title: "MORE AGENTS", label: "5-8" });
  });

  it("grid mode with three providers merges the centre two segments into one 400-wide panel", () => {
    const panels = grid([provider("claude"), provider("codex"), provider("deepseek")]);
    expect(panels).toHaveLength(3);
    expect(panels[1].region).toMatchObject({ x: 200, width: 400, height: 100 });
    expect(panels[1].content).toMatchObject({ kind: "providers" });
    expect(panels[1].content.kind === "providers" && panels[1].content.model.rows.map((row) => row.label)).toEqual([
      "claude",
      "codex",
      "deepseek",
    ]);
    // The pager keeps its own segment either way.
    expect(panels[2].region).toMatchObject({ x: 600, width: 200 });
  });

  it("grid mode scrolls the merged panel by the provider offset, without moving the panel", () => {
    const providers = ["a", "b", "c", "d", "e"].map((label) => provider(label));
    expect(providerLabels(grid(providers, 0)[1])).toEqual(["a", "b", "c"]);
    expect(providerLabels(grid(providers, 2)[1])).toEqual(["c", "d", "e"]);
    // Scrolling is a content change only; the panel that owns the region does
    // not move, so the renderer still diffs it against the same region.
    expect(grid(providers, 2)[1].region).toEqual(grid(providers, 0)[1].region);
    expect(tilesTheStrip(grid(providers, 2))).toBe(true);
  });

  it("grid mode leaves an unused provider segment blank rather than claiming a provider", () => {
    const panels = grid([provider("claude")]);
    expect(panels[1].content).toMatchObject({ kind: "provider", row: { label: "claude" } });
    expect(panels[2].content).toEqual({ kind: "blank" });
    expect(grid([])[1].content).toEqual({ kind: "blank" });
  });

  it("cmd mode is one full-width panel carrying the whole agent readout", () => {
    const panels = composeStrip({
      mode: "cmd",
      data: {
        detail: agentDetailModel({
          identifier: "1356",
          title: "Restore retry statistics",
          bucket: "running",
          progress_percent: 40,
          activity: "review",
          runtime_seconds: 3_600,
        }),
      },
    });
    expect(panels).toHaveLength(1);
    expect(panels[0].region).toMatchObject({ x: 0, y: 0, width: 800, height: 100 });
    expect(panels[0].content).toMatchObject({
      kind: "agentDetail",
      model: { ticketId: "1356", title: "Restore retry statistics", percent: 40, elapsedLabel: "1h 00m" },
    });
  });

  it("logs mode is one full-width panel carrying every row it was given", () => {
    const rows = [message("first"), message("second"), message("third")];
    const panels = composeStrip({ mode: "logs", data: { rows } });
    expect(panels).toHaveLength(1);
    expect(panels[0].region.width).toBe(800);
    expect(panels[0].content).toMatchObject({ kind: "chatLog", rows });
  });

  it("logs mode carries each row shape through to the painter", () => {
    const header: TranscriptRow = { kind: "event_header", badge: "EMIT", body: "Dependency cleared", label: "Dependency cleared", timestamp: "2026-08-13T03:00:00Z" };
    const diff: TranscriptRow = { kind: "diff", path: "lib/a.ex", additions: 3, deletions: 1, line: null };
    const [panel] = composeStrip({ mode: "logs", data: { rows: [header, diff] } });
    expect(panel.content).toMatchObject({ kind: "chatLog", rows: [header, diff] });
  });

  describe("cmd mode and the voice readout", () => {
    const cmd = (voiceData?: VoicePanelData) =>
      composeStrip({ mode: "cmd", data: { detail: agentDetailModel({ identifier: "1356" }), voice: voiceData } })[0];

    it("keeps the agent readout when the host has no voice session", () => {
      expect(cmd().content.kind).toBe("agentDetail");
    });

    it("shows the voice readout while the mic is held", () => {
      expect(cmd(voice({ holding: true })).content).toMatchObject({ kind: "voice", data: { holding: true } });
    });

    // The keys that act on the buffer appear at the same moment, and pressing
    // Send without being able to read what will be sent is a coin toss.
    it("keeps the voice readout up after the release while the buffer holds text", () => {
      expect(cmd(voice({ holding: false, text: "run the tests" })).content).toMatchObject({
        kind: "voice",
        data: { text: "run the tests" },
      });
    });

    it("returns to the agent readout once the buffer is empty and the key is up", () => {
      expect(cmd(voice({ holding: false, text: "" })).content.kind).toBe("agentDetail");
    });

    it("is still one full-width panel either way", () => {
      expect(cmd(voice({ holding: true })).region).toMatchObject({ x: 0, width: 800 });
    });
  });

  describe("settings mode", () => {
    it("is one full-width panel naming the selected microphone", () => {
      const panels = settings();
      expect(panels).toHaveLength(1);
      expect(panels[0].region).toMatchObject({ x: 0, y: 0, width: 800, height: 100 });
      expect(panels[0].content).toEqual({
        kind: "settings",
        selectedLabel: "Yeti X",
        deviceCount: 3,
        pageLabel: "1/1",
      });
    });

    // A headless box is not a broken box; the painter says so from the count.
    it("carries a zero device count through rather than hiding it", () => {
      expect(settings({ selectedLabel: "", deviceCount: 0 })[0].content).toMatchObject({ deviceCount: 0 });
    });

    it("shows the voice readout while TestMic is held", () => {
      expect(settings({ voice: voice({ holding: true }) })[0].content).toMatchObject({ kind: "voice" });
    });

    // Unlike cmd there is no buffer to read back here: TestMic answers "does
    // this microphone hear me *now*", so the readout goes with the key.
    it("returns to the settings readout the moment TestMic is released", () => {
      expect(settings({ voice: voice({ holding: false, text: "leftovers" }) })[0].content.kind).toBe("settings");
    });
  });

  it("logs mode normalises the four independent scroll bounds", () => {
    const [both] = composeStrip({
      mode: "logs",
      data: { rows: [message("chat")], chatHasNext: true, eventHasPrevious: true, eventHasNext: true },
    });
    expect(both.content).toMatchObject({
      chatHasPrevious: false,
      chatHasNext: true,
      eventHasPrevious: true,
      eventHasNext: true,
    });

    const [none] = composeStrip({ mode: "logs", data: { rows: [] } });
    expect(none.content).toMatchObject({
      chatHasPrevious: false,
      chatHasNext: false,
      eventHasPrevious: false,
      eventHasNext: false,
    });

    const [previous] = composeStrip({ mode: "logs", data: { rows: [], chatHasPrevious: true } });
    expect(previous.content).toMatchObject({ chatHasPrevious: true, chatHasNext: false });
  });
});
