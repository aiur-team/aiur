import { describe, expect, it } from "vitest";

import { measureKeyRepaintLatency } from "../../src/keys/keyLatency.js";
import { KEY_MAX_PAYLOAD } from "../../src/keys/keyImage.js";

describe("measureKeyRepaintLatency", () => {
  it("reports per-key vs full-panel timing and transfer counts with an injected clock", () => {
    const ticks = [0, 10, 20, 42]; // singleStart, singleEnd, fullStart, fullEnd
    let i = 0;
    const now = () => ticks[i++];

    const result = measureKeyRepaintLatency(KEY_MAX_PAYLOAD + 1, 2, now);
    expect(result.singleKeyMs).toBe(5); // (10 - 0) / 2
    expect(result.fullPanelMs).toBe(11); // (42 - 20) / 2
    expect(result.singleKeyReports).toBe(2); // one payload over max -> 2 chunks
    expect(result.fullPanelReports).toBe(16); // 8 keys x 2 chunks
  });

  it("clamps a negative size to an empty image and defaults its clock", () => {
    const result = measureKeyRepaintLatency(-5, 1);
    expect(result.singleKeyReports).toBe(1);
    expect(result.fullPanelReports).toBe(8);
    expect(Number.isFinite(result.singleKeyMs)).toBe(true);
  });
});
