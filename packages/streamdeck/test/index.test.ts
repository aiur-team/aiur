import { describe, expect, it } from "vitest";

import {
  MICS_PER_PAGE,
  MIC_KEY_INDICES,
  StripRenderer,
  VOICE_WAVEFORM_COLUMNS,
  buildRegionReports,
  composeStrip,
  createRepaintCoalescer,
  createVoiceLink,
  settingsView,
  summaryModel,
  voicePanel,
} from "../src/index.js";

describe("Stream Deck package", () => {
  it("re-exports the touch-strip public surface", () => {
    expect(typeof buildRegionReports).toBe("function");
    expect(typeof composeStrip).toBe("function");
    expect(typeof summaryModel).toBe("function");
    expect(typeof StripRenderer).toBe("function");
  });

  it("re-exports the voice surface", () => {
    expect(typeof settingsView).toBe("function");
    expect(typeof voicePanel).toBe("function");
    expect(typeof createVoiceLink).toBe("function");
    expect(typeof createRepaintCoalescer).toBe("function");
    expect(MICS_PER_PAGE).toBe(6);
    expect(MIC_KEY_INDICES).toEqual([0, 1, 3, 4, 5, 6]);
    expect(VOICE_WAVEFORM_COLUMNS).toBeGreaterThan(0);
  });
});
