import { describe, expect, it } from "vitest";

import { COMMANDS_ERROR, OPEN_AMBER } from "../../src/art/segments.js";
import type { SegmentContent } from "../../src/touchStrip/stripLayout.js";
import { agentDetailModel } from "../../src/touchStrip/agentDetail.js";
import { VOICE_HOLD_PROMPT, VOICE_LISTENING, VOICE_WAVEFORM_COLUMNS, voicePanel } from "../../src/voicePanel.js";
import type { WaveformColumn } from "../../src/audio/index.js";
import { BACKGROUND, render } from "./renderSegment.js";
import {
  LABEL,
  ACCENT_LIVE,
  pixelAt,
  drew,
} from "./segmentFixtures.js";

describe("agent detail panel", () => {
  const detail = (agent: Readonly<Record<string, unknown>>): SegmentContent => ({
    kind: "agentDetail",
    model: agentDetailModel(agent),
  });

  it("reads like the agent's key: ticket, full title, percent, bar and BACK", () => {
    const { ink } = render(
      detail({
        identifier: "401",
        title: "Auth refactor and session rotation",
        icon: "key",
        vendor: "claude",
        bucket: "running",
        progress_percent: 72,
      }),
      800,
    );
    expect(drew(ink, "401")).toBeDefined();
    expect(drew(ink, "Auth refactor and session rotation")).toBeDefined();
    expect(drew(ink, "72%")).toBeDefined();
    expect(drew(ink, "RUNNING")).toBeDefined();
    expect(drew(ink, "‹ BACK  ")).toBeDefined();
  });

  it("shows the agent's activity and how long it has been at it", () => {
    const withActivity = render(detail({ identifier: "401", bucket: "running", activity: "waiting_ci", runtime_seconds: 11_240 }), 800);
    expect(drew(withActivity.ink, "Waiting on CI")).toBeDefined();
    expect(drew(withActivity.ink, "ELAPSED")).toBeDefined();
    expect(drew(withActivity.ink, "3h 07m")).toBeDefined();

    // The glyph is drawn, not merely resolved: the label alone would still read
    // correctly with the icon call deleted.
    const withoutGlyph = render(detail({ identifier: "401", bucket: "running", runtime_seconds: 11_240 }), 800);
    expect(withActivity.inked).toBeGreaterThan(withoutGlyph.inked);
  });

  // The daemon sends no activity for an agent with no fresh stage and no
  // actionable wait. Inventing one there would be a lie on a glanceable surface.
  it("omits the activity and the elapsed time when the daemon sent neither", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "running" }), 800);
    expect(ink.some((entry) => entry.text === "ELAPSED")).toBe(false);
    expect(ink.some((entry) => entry.text.startsWith("Waiting"))).toBe(false);
    expect(drew(ink, "RUNNING")).toBeDefined();
  });

  // The bucket crosses the wire as a free string. A state the contract has not
  // learned yet must degrade to its own name, not take the repaint down.
  it("survives a bucket the key-face contract does not define", () => {
    expect(drew(render(detail({ identifier: "401", bucket: "hibernating" }), 800).ink, "HIBERNATING")).toBeDefined();
  });

  // The status is a free string off the wire and shares its baseline with the
  // right-aligned elapsed reading, so it needs a real budget rather than the
  // contract's short labels happening to fit.
  it("clips an over-long status rather than overprinting the elapsed reading", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "h".repeat(200), runtime_seconds: 11_240 }), 800);
    expect(drew(ink, "3h 07m")).toBeDefined();
    expect(ink.find((entry) => entry.text.startsWith("HHH"))?.text.endsWith("…")).toBe(true);
  });

  it("uses one green fill, a solid zero stub, and a brighter completion shade", () => {
    const empty = render(detail({ identifier: "401", bucket: "queued", progress_percent: 0 }), 800);
    const some = render(detail({ identifier: "401", bucket: "running", progress_percent: 60 }), 800);
    const complete = render(detail({ identifier: "401", bucket: "running", progress_percent: 100 }), 800);
    expect(drew(empty.ink, "0%")).toBeDefined();
    expect(empty.inked).toBeGreaterThan(0);
    expect(empty.inked).toBeLessThan(some.inked);
    expect(pixelAt(empty.pixels, 800, 211, 79)).toEqual([63, 185, 80]);
    expect(pixelAt(some.pixels, 800, 300, 79)).toEqual([63, 185, 80]);
    expect(pixelAt(complete.pixels, 800, 300, 79)).toEqual([116, 212, 127]);
  });

  it("paints unknown progress as flat grey, distinct from a measured zero", () => {
    const unknown = render(detail({ identifier: "401", bucket: "running", progress_percent: null }), 800);
    const zero = render(detail({ identifier: "401", bucket: "running", progress_percent: 0 }), 800);

    expect(drew(unknown.ink, "—")).toBeDefined();
    expect(drew(zero.ink, "0%")).toBeDefined();
    expect(Array.from(unknown.pixels)).not.toEqual(Array.from(zero.pixels));
    const neutral = pixelAt(unknown.pixels, 800, 300, 79);
    expect(neutral).toEqual([68, 70, 73]);
    expect(neutral).toEqual(pixelAt(unknown.pixels, 800, 306, 79));
    expect(neutral).not.toEqual(pixelAt(zero.pixels, 800, 300, 79));
  });

  it("renders a stale detail fill the same as a fresh one", () => {
    const fresh = render(detail({ identifier: "401", bucket: "running", progress_percent: 60, progress_freshness: "fresh" }), 800);
    const stale = render(detail({ identifier: "401", bucket: "running", progress_percent: 60, progress_freshness: "stale" }), 800);

    expect(Array.from(stale.pixels)).toEqual(Array.from(fresh.pixels));
  });

  it("clips an over-long title rather than running it under the percentage", () => {
    const { ink } = render(detail({ identifier: "401", bucket: "running", title: "word ".repeat(60), progress_percent: 50 }), 800);
    expect(drew(ink, "50%")).toBeDefined();
    expect(ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });
});

describe("blank panel", () => {
  // A provider slot with no provider configured for it. An "Awaiting data"
  // label here would claim a provider that does not exist.
  it("draws nothing at all", () => {
    expect(render({ kind: "blank" }).ink).toEqual([]);
  });
});

describe("voice panel", () => {
  const columns = (shape: (index: number) => number): WaveformColumn[] =>
    Array.from({ length: VOICE_WAVEFORM_COLUMNS }, (_, index) => ({ min: -shape(index), max: shape(index) }));

  const panel = (over: Partial<Parameters<typeof voicePanel>[0]> = {}): SegmentContent => ({
    kind: "voice",
    data: voicePanel({
      columns: columns(() => 0),
      dbfs: -60,
      text: "",
      holding: false,
      unavailableReason: null,
      ...over,
    }),
  });

  it("prints the hold prompt and the placeholder when idle", () => {
    const { ink } = render(panel(), 800);
    expect(drew(ink, VOICE_HOLD_PROMPT)).toBeDefined();
    expect(drew(ink, "Nothing heard yet.")).toBeDefined();
  });

  it("prints LISTENING in the live accent while the key is held", () => {
    const { ink } = render(panel({ holding: true }), 800);
    expect(drew(ink, VOICE_LISTENING)?.fill).toBe(ACCENT_LIVE);
    expect(drew(ink, "Listening…")).toBeDefined();
  });

  it("prints the transcribed text once there is some", () => {
    expect(drew(render(panel({ text: "run the tests again" }), 800).ink, "run the tests again")).toBeDefined();
  });

  it("clips over-long text rather than running it off the panel", () => {
    const { ink } = render(panel({ text: "word ".repeat(300) }), 800);
    expect(ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });

  /**
   * The reason the split exists. A missing key is a configuration problem, and
   * blanking the trace would present it as a dead microphone.
   */
  it("keeps the trace and the bar when transcription is unavailable", () => {
    const reason = "Aiur has no ElevenLabs API key - transcription is off";
    const off = render(panel({ unavailableReason: reason, dbfs: -6, columns: columns(() => 0.8) }), 800);
    expect(drew(off.ink, reason.toUpperCase())).toBeDefined();
    // Same trace, same bar, whether or not the reason is set.
    const on = render(panel({ dbfs: -6, columns: columns(() => 0.8) }), 800);
    expect(off.inked).toBeGreaterThan(render(panel(), 800).inked);
    expect(Math.abs(off.inked - on.inked)).toBeLessThan(on.inked / 4);
  });

  // Every column carries a min/max pair. A rectified trace is a solid blob;
  // peaks above and valleys below the centre are what read as speech.
  it("draws each column above and below the centre line", () => {
    const { pixels } = render(panel({ columns: columns(() => 0.9) }), 800);
    const centre = 36;
    const above = pixelAt(pixels, 800, 20, centre - 20);
    const below = pixelAt(pixels, 800, 20, centre + 20);
    expect(above).not.toEqual([...BACKGROUND]);
    expect(below).not.toEqual([...BACKGROUND]);
  });

  /**
   * The scroll direction: `createWaveformScroll` emits oldest-first, so column
   * `i` maps straight to the `i`-th x position and the newest audio is the
   * right-hand edge. A ramp therefore has to grow left to right.
   */
  it("puts the newest column at the right edge", () => {
    const ramp = columns((index) => (index / VOICE_WAVEFORM_COLUMNS) * 0.95);
    const { pixels } = render(panel({ columns: ramp }), 800);
    const spread = (x: number): number => {
      let top = 100;
      let bottom = 0;
      for (let y = 10; y < 62; y += 1) {
        if (pixelAt(pixels, 800, x, y).join() !== [...BACKGROUND].join()) {
          top = Math.min(top, y);
          bottom = Math.max(bottom, y);
        }
      }
      return bottom - top;
    };
    // The trace band runs from PAD to just short of the decibel bar.
    expect(spread(700)).toBeGreaterThan(spread(60));
  });

  /**
   * The bar is a *height*, taken from `dbfsToFill`, which is already linear in
   * decibels. Measured down the bar's own column rather than by total ink,
   * because the track is painted at every level and would swamp the difference.
   */
  const barHeight = (dbfs: number): number => {
    const { pixels } = render(panel({ dbfs }), 800);
    // The bar sits at width - PAD - DB_BAR_WIDTH; 780 is inside it.
    let filled = 0;
    for (let y = 10; y < 62; y += 1) {
      const [r, g] = pixelAt(pixels, 800, 780, y);
      if (Math.max(r, g) > 120) filled += 1;
    }
    return filled;
  };

  it("grows the decibel bar with the level, linearly in decibels", () => {
    expect(barHeight(-60)).toBe(0);
    const half = barHeight(-30);
    const loud = barHeight(-3);
    expect(half).toBeGreaterThan(0);
    expect(loud).toBeGreaterThan(half);
    // -30 dBFS is halfway up a -60 dB scale; a bar re-mapped to amplitude would
    // sit at about 3% instead.
    expect(half / loud).toBeGreaterThan(0.4);
    expect(half / loud).toBeLessThan(0.6);
  });

  it("prints the decibel reading beside the bar", () => {
    expect(drew(render(panel({ dbfs: -3 }), 800).ink, "-3")).toBeDefined();
  });
});

describe("settings panel", () => {
  const settings = (over: Partial<Extract<SegmentContent, { kind: "settings" }>> = {}): SegmentContent => ({
    kind: "settings",
    selectedLabel: "Yeti X Analog Stereo",
    deviceCount: 3,
    pageLabel: "1/1",
    ...over,
  });

  it("names the microphone capture will open, the count and the page", () => {
    const { ink } = render(settings(), 800);
    expect(drew(ink, "MICROPHONE")).toBeDefined();
    expect(drew(ink, "Yeti X Analog Stereo")).toBeDefined();
    expect(drew(ink, "3 found · page 1/1")).toBeDefined();
    expect(drew(ink, "HOLD TESTMIC TO CHECK LEVELS")?.fill).toBe(ACCENT_LIVE);
  });

  // A headless box has no microphone and that is not a fault, so the panel says
  // so rather than showing an empty selection that reads as broken.
  it("says so when there is no microphone at all", () => {
    const { ink } = render(settings({ selectedLabel: "", deviceCount: 0 }), 800);
    expect(drew(ink, "No microphones")).toBeDefined();
    expect(drew(ink, "Attach a microphone, then reopen settings")).toBeDefined();
    expect(drew(ink, "HOLD TESTMIC TO CHECK LEVELS")?.fill).toBe(LABEL);
  });

  it("clips a long device name rather than running it off the panel", () => {
    const { ink } = render(settings({ selectedLabel: "Yeti ".repeat(80) }), 800);
    expect(ink.some((entry) => entry.text.endsWith("…"))).toBe(true);
  });

  it("carries the BACK hint, because dial A is what performs it", () => {
    expect(render(settings(), 800).ink.some((entry) => entry.text.includes("BACK"))).toBe(true);
  });
});

describe("commands panel", () => {
  const commands = (over: Partial<Extract<SegmentContent, { kind: "commands" }>> = {}): Extract<SegmentContent, { kind: "commands" }> => ({
    kind: "commands",
    model: {
      view: "detail",
      ticketId: "AIUR-1",
      activeCount: 1,
      total: 3,
      page: "1/1",
      title: "Ship the change?",
      description: "Merge and deploy now.",
      status: "OPEN",
      answerable: true,
      approving: false,
      recorded: null,
    },
    ...over,
  });

  it("history view names the open count and the reading hint", () => {
    const model = {
      view: "history" as const,
      ticketId: "AIUR-1",
      activeCount: 2,
      total: 3,
      page: "1/2",
      title: "Commands",
      description: "2 awaiting your answer",
      status: "OPEN",
      answerable: false,
      approving: false,
      recorded: null,
    };
    const { ink } = render({ kind: "commands", model }, 800);
    expect(drew(ink, "COMMANDS")).toBeDefined();
    expect(drew(ink, "2 awaiting your answer")).toBeDefined();
    expect(drew(ink, "PRESS A KEY TO READ IT")).toBeDefined();
    expect(ink.some((entry) => entry.text.includes("BACK"))).toBe(true);
  });

  it("history view says so when there are no open Commands", () => {
    const model = {
      view: "history" as const,
      ticketId: "AIUR-1",
      activeCount: 0,
      total: 3,
      page: "",
      title: "Commands",
      description: "No open Commands",
      status: "CLEAR",
      answerable: false,
      approving: false,
      recorded: null,
    };
    const { ink } = render({ kind: "commands", model }, 800);
    expect(drew(ink, "No open Commands")).toBeDefined();
  });

  it("detail view paints the question, description and status", () => {
    const { ink } = render(commands(), 800);
    expect(drew(ink, "Ship the change?")).toBeDefined();
    expect(drew(ink, "Merge and deploy now.")).toBeDefined();
    expect(drew(ink, "OPEN")?.fill).toBe(OPEN_AMBER);
  });

  it("paints the green APPROVE affordance only when an answer is armed", () => {
    expect(drew(render(commands({ model: { ...commands().model, approving: true } }), 800).ink, "DIAL D · APPROVE")?.fill).toBe(ACCENT_LIVE);
    expect(drew(render(commands(), 800).ink, "READ AN OPTION OR HOLD MIC")).toBeDefined();
  });

  it("read-only detail paints what was decided with no approval affordance", () => {
    const model = {
      view: "detail" as const,
      ticketId: "AIUR-1",
      activeCount: 0,
      total: 3,
      page: "",
      title: "Ship the change?",
      description: "Merge and deploy now.",
      status: "ANSWERED",
      answerable: false,
      approving: false,
      recorded: "Chose: Ship it",
    };
    const { ink } = render({ kind: "commands", model }, 800);
    expect(drew(ink, "Chose: Ship it")?.fill).toBe(ACCENT_LIVE);
    expect(drew(ink, "DIAL D · APPROVE")).toBeUndefined();
    expect(ink.some((entry) => entry.text.includes("BACK"))).toBe(true);
  });

  it("shows a channel error instead of the reading so a refused answer is never silent", () => {
    const { ink } = render({ kind: "commands", model: { ...commands().model, error: "command_not_focused" } }, 800);
    expect(drew(ink, "ERROR")?.fill).toBe(COMMANDS_ERROR);
    expect(drew(ink, "command_not_focused")).toBeDefined();
    expect(drew(ink, "Ship the change?")).toBeUndefined();
    expect(ink.some((entry) => entry.text.includes("BACK"))).toBe(true);
  });
});
