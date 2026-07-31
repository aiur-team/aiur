import { describe, expect, it } from "vitest";

import {
  DIAL_DRAG_DIVISOR,
  DIAL_MAX,
  DIAL_MIN,
  DIAL_STEP,
  DIAL_SWEEP_DEGREES,
  PRESS_THRESHOLD_DEGREES,
  applyDragDelta,
  applyStep,
  clampDial,
  columnOffsetFromDial,
  currentWindow,
  cycleEventPage,
  cycleWindow,
  dial3ValueFromEventOffset,
  dial3ValueFromOffset,
  dialRotationCss,
  eventOffsetFromDial,
  isPress,
  maxColumnOffset,
  maxEventOffset,
  resetDials,
  windowCount,
  windowStopPosition,
} from "../src/dial.js";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

describe("dial constants", () => {
  it("has a 270-degree sweep", () => {
    expect(DIAL_SWEEP_DEGREES).toBe(270);
  });

  it("has a drag divisor of 2.7", () => {
    expect(DIAL_DRAG_DIVISOR).toBe(2.7);
  });

  it("has a step of 4", () => {
    expect(DIAL_STEP).toBe(4);
  });

  it("has a press threshold of 8 degrees", () => {
    expect(PRESS_THRESHOLD_DEGREES).toBe(8);
  });

  it("has value range 0–100", () => {
    expect(DIAL_MIN).toBe(0);
    expect(DIAL_MAX).toBe(100);
  });
});

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

describe("dialRotationCss", () => {
  it("returns -135deg at value 0", () => {
    expect(dialRotationCss(0)).toBe("-135deg");
  });

  it("returns 135deg at value 100", () => {
    expect(dialRotationCss(100)).toBe("135deg");
  });

  it("returns 0deg at value 50", () => {
    expect(dialRotationCss(50)).toBe("0deg");
  });
});

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

describe("clampDial", () => {
  it("clamps values below 0 to 0", () => {
    expect(clampDial(-10)).toBe(0);
    expect(clampDial(-1)).toBe(0);
  });

  it("clamps values above 100 to 100", () => {
    expect(clampDial(101)).toBe(100);
    expect(clampDial(200)).toBe(100);
  });

  it("passes through in-range values", () => {
    expect(clampDial(0)).toBe(0);
    expect(clampDial(50)).toBe(50);
    expect(clampDial(100)).toBe(100);
  });
});

describe("applyDragDelta", () => {
  it("converts delta_degrees / 2.7 and adds to current value", () => {
    // 27 degrees / 2.7 = 10 value units
    expect(applyDragDelta(50, 27)).toBe(60);
  });

  it("clamps at 100", () => {
    expect(applyDragDelta(95, 270)).toBe(100);
  });

  it("clamps at 0", () => {
    expect(applyDragDelta(5, -270)).toBe(0);
  });

  it("handles negative delta (turning back)", () => {
    expect(applyDragDelta(50, -27)).toBe(40);
  });
});

describe("applyStep", () => {
  it("increments by DIAL_STEP", () => {
    expect(applyStep(50, 1)).toBe(54);
  });

  it("decrements by DIAL_STEP", () => {
    expect(applyStep(50, -1)).toBe(46);
  });

  it("clamps at 100 on increment", () => {
    expect(applyStep(98, 1)).toBe(100);
  });

  it("clamps at 0 on decrement", () => {
    expect(applyStep(2, -1)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Press vs. turn discrimination
// ---------------------------------------------------------------------------

describe("isPress", () => {
  it("returns true below 8 degrees", () => {
    expect(isPress(0)).toBe(true);
    expect(isPress(7.9)).toBe(true);
    expect(isPress(7)).toBe(true);
  });

  it("returns false at exactly 8 degrees", () => {
    expect(isPress(8)).toBe(false);
  });

  it("returns false above 8 degrees", () => {
    expect(isPress(8.1)).toBe(false);
    expect(isPress(270)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Paging math — grid mode
// ---------------------------------------------------------------------------

describe("maxColumnOffset", () => {
  it("returns 0 for 0 agents", () => {
    expect(maxColumnOffset(0)).toBe(0);
  });

  it("returns 0 for 1 agent", () => {
    expect(maxColumnOffset(1)).toBe(0);
  });

  it("returns 0 for 8 agents (exactly one page)", () => {
    // ceil(8/2) - 4 = 4 - 4 = 0
    expect(maxColumnOffset(8)).toBe(0);
  });

  it("returns 1 for 9 agents", () => {
    // ceil(9/2) - 4 = 5 - 4 = 1
    expect(maxColumnOffset(9)).toBe(1);
  });

  it("returns a positive value for a large agent count", () => {
    // ceil(32/2) - 4 = 16 - 4 = 12
    expect(maxColumnOffset(32)).toBe(12);
  });
});

describe("windowCount", () => {
  it("returns 1 for 0 agents", () => {
    expect(windowCount(0)).toBe(1);
  });

  it("returns 1 for 1 agent", () => {
    expect(windowCount(1)).toBe(1);
  });

  it("returns 1 for 8 agents", () => {
    expect(windowCount(8)).toBe(1);
  });

  it("returns 2 for 9 agents", () => {
    expect(windowCount(9)).toBe(2);
  });

  it("returns 4 for 32 agents", () => {
    expect(windowCount(32)).toBe(4);
  });
});

describe("columnOffsetFromDial", () => {
  it("returns 0 when dial is 0", () => {
    expect(columnOffsetFromDial(0, 32)).toBe(0);
  });

  it("returns maxOffset when dial is 100", () => {
    const count = 32;
    expect(columnOffsetFromDial(100, count)).toBe(maxColumnOffset(count));
  });

  it("rounds to nearest integer", () => {
    // maxOffset = 12 for 32 agents; 50% of 12 = 6
    expect(columnOffsetFromDial(50, 32)).toBe(6);
  });

  it("returns 0 for any dial value when agentCount is 0", () => {
    expect(columnOffsetFromDial(100, 0)).toBe(0);
  });
});

describe("windowStopPosition", () => {
  it("is 0 for window 0", () => {
    expect(windowStopPosition(0, 32)).toBe(0);
  });

  it("is window * 4 when below maxOffset", () => {
    // maxOffset = 12 for 32 agents; window 1 → min(4, 12) = 4
    expect(windowStopPosition(1, 32)).toBe(4);
    expect(windowStopPosition(2, 32)).toBe(8);
    expect(windowStopPosition(3, 32)).toBe(12);
  });

  it("is clamped at maxOffset", () => {
    // 9 agents: maxOffset = 1; window 1 → min(4, 1) = 1
    expect(windowStopPosition(1, 9)).toBe(1);
  });
});

describe("currentWindow", () => {
  it("returns 0 when offset is 0", () => {
    expect(currentWindow(0, 32)).toBe(0);
  });

  it("returns the highest window whose stop is ≤ offset", () => {
    // 32 agents: window stops at 0, 4, 8, 12
    expect(currentWindow(3, 32)).toBe(0);
    expect(currentWindow(4, 32)).toBe(1);
    expect(currentWindow(7, 32)).toBe(1);
    expect(currentWindow(8, 32)).toBe(2);
    expect(currentWindow(12, 32)).toBe(3);
  });

  it("returns 0 for 0 agents", () => {
    expect(currentWindow(0, 0)).toBe(0);
  });
});

describe("cycleWindow", () => {
  it("advances from window 0 to window 1 and back-computes dial value", () => {
    const result = cycleWindow(0, 32);
    // window 1 stop = 4; maxOffset = 12; dial = round(4/12 * 100) = 33
    expect(result.columnOffset).toBe(4);
    expect(result.dial3Value).toBe(33);
  });

  it("wraps from the last window back to 0", () => {
    // 32 agents: 4 windows; last window is 3 at offset 12
    const result = cycleWindow(12, 32);
    expect(result.columnOffset).toBe(0);
    expect(result.dial3Value).toBe(0);
  });

  it("returns offset 0 and dial 0 when there is only one window", () => {
    const result = cycleWindow(0, 8);
    expect(result.columnOffset).toBe(0);
    expect(result.dial3Value).toBe(0);
  });

  it("does not visually rotate — dial3Value is back-computed, not incremented", () => {
    // After cycle the stored dial3Value must equal what dial3ValueFromOffset gives
    const { columnOffset, dial3Value } = cycleWindow(0, 32);
    expect(dial3Value).toBe(dial3ValueFromOffset(columnOffset, 32));
  });
});

describe("dial3ValueFromOffset", () => {
  it("returns 0 when offset is 0", () => {
    expect(dial3ValueFromOffset(0, 32)).toBe(0);
  });

  it("returns 100 at maxOffset", () => {
    expect(dial3ValueFromOffset(maxColumnOffset(32), 32)).toBe(100);
  });

  it("returns 0 for any offset when agentCount produces maxOffset 0", () => {
    expect(dial3ValueFromOffset(0, 0)).toBe(0);
    expect(dial3ValueFromOffset(0, 8)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Paging math — logs mode
// ---------------------------------------------------------------------------

describe("maxEventOffset", () => {
  it("returns 0 for 0 events", () => {
    expect(maxEventOffset(0)).toBe(0);
  });

  it("returns 0 for 8 events", () => {
    expect(maxEventOffset(8)).toBe(0);
  });

  it("returns 1 for 9 events", () => {
    expect(maxEventOffset(9)).toBe(1);
  });

  it("returns eventCount - 8 for larger counts", () => {
    expect(maxEventOffset(20)).toBe(12);
    expect(maxEventOffset(100)).toBe(92);
  });
});

describe("eventOffsetFromDial", () => {
  it("returns 0 when dial is 0", () => {
    expect(eventOffsetFromDial(0, 20)).toBe(0);
  });

  it("returns maxEventOffset when dial is 100", () => {
    expect(eventOffsetFromDial(100, 20)).toBe(maxEventOffset(20));
  });

  it("returns 0 for any dial when eventCount is ≤ 8", () => {
    expect(eventOffsetFromDial(100, 8)).toBe(0);
    expect(eventOffsetFromDial(100, 0)).toBe(0);
  });
});

describe("cycleEventPage", () => {
  it("advances to the next event page and back-computes dial value", () => {
    // 20 events: pages 0 (offset 0) and 1 (offset 8); maxEventOffset = 12
    const result = cycleEventPage(0, 20);
    expect(result.eventOffset).toBe(8);
    expect(result.dial3Value).toBe(dial3ValueFromEventOffset(8, 20));
  });

  it("wraps from last page back to offset 0", () => {
    // 20 events: page starting at offset 16 → next wraps to page 0 (offset 0)
    const result = cycleEventPage(16, 20);
    expect(result.eventOffset).toBe(0);
    expect(result.dial3Value).toBe(0);
  });

  it("returns offset 0 and dial 0 when eventCount ≤ 8", () => {
    expect(cycleEventPage(0, 8)).toEqual({ eventOffset: 0, dial3Value: 0 });
    expect(cycleEventPage(0, 0)).toEqual({ eventOffset: 0, dial3Value: 0 });
  });

  it("clamps event offset at maxEventOffset", () => {
    // 9 events: maxEventOffset = 1; page 1 offset = min(8, 1) = 1
    const result = cycleEventPage(0, 9);
    expect(result.eventOffset).toBe(1);
    expect(result.dial3Value).toBe(100);
  });

  it("does not visually rotate — dial3Value is back-computed from offset", () => {
    const { eventOffset, dial3Value } = cycleEventPage(0, 20);
    expect(dial3Value).toBe(dial3ValueFromEventOffset(eventOffset, 20));
  });
});

describe("dial3ValueFromEventOffset", () => {
  it("returns 0 when offset is 0", () => {
    expect(dial3ValueFromEventOffset(0, 20)).toBe(0);
  });

  it("returns 100 at maxEventOffset", () => {
    expect(dial3ValueFromEventOffset(maxEventOffset(20), 20)).toBe(100);
  });

  it("returns 0 when eventCount ≤ 8", () => {
    expect(dial3ValueFromEventOffset(0, 8)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

describe("resetDials", () => {
  it("returns dials 0, 1, and 2 set to zero", () => {
    expect(resetDials()).toEqual({ dial0Value: 0, dial1Value: 0, dial2Value: 0 });
  });

  it("does not include dial 3 (view-state, managed separately)", () => {
    expect(resetDials()).not.toHaveProperty("dial3Value");
  });
});
