import { describe, expect, it } from "vitest";

import {
  MICS_PER_PAGE,
  MIC_KEY_INDICES,
  VOICE_WAVEFORM_COLUMNS,
  createRepaintCoalescer,
  createVoiceLink,
  settingsView,
  voicePanel,
} from "../src/index.js";

describe("Stream Deck package", () => {
  it("re-exports the voice surface", () => {
    expect(typeof settingsView).toBe("function");
    expect(typeof voicePanel).toBe("function");
    expect(typeof createVoiceLink).toBe("function");
    expect(typeof createRepaintCoalescer).toBe("function");
    expect(MICS_PER_PAGE).toBe(7);
    expect(MIC_KEY_INDICES).toEqual([0, 1, 2, 3, 4, 5, 6]);
    expect(VOICE_WAVEFORM_COLUMNS).toBeGreaterThan(0);
  });
});
