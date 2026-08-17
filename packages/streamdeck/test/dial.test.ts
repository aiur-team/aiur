import type { ModeDialState } from "../src/mode.js";

import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

import {
  DIAL_DRAG_DIVISOR,
  DIAL_MAX,
  DIAL_MIN,
  DIAL_STEP,
  DIAL_SWEEP_DEGREES,
  PRESS_THRESHOLD_DEGREES,
  _assertDialResetSatisfiesModeDialState,
  applyDragDelta,
  applyStep,
  clampDial,
  columnOffsetFromDial,
  currentWindow,
  cycleEventPage,
  cycleWindow,
  dial3TurnOffset,
  dial3ValueFromEventOffset,
  dial3ValueFromOffset,
  dialPressAction,
  dialRotationCss,
  eventOffsetFromDial,
  isPress,
  maxColumnOffset,
  maxEventOffset,
  resetDials,
  windowCount,
  windowStopPosition,
} from "../src/dial.js";

const emulatorHookSource = readFileSync(
  new URL("../../../src/priv/static/streamdeck-emulator-hook.js", import.meta.url),
  "utf8",
);

const emulatorHookConstant = (name: string): number => {
  const match = emulatorHookSource.match(new RegExp(`var ${name} = ([0-9.]+);`));
  if (!match) throw new Error(`Missing numeric ${name} in Stream Deck emulator hook`);
  return Number(match[1]);
};

// ---------------------------------------------------------------------------
// Constants — real behaviour assertions, not tautologies
// ---------------------------------------------------------------------------

describe("dial constants", () => {
  it("keeps emulator drag and press constants aligned with package semantics", () => {
    expect(emulatorHookConstant("DRAG_DIVISOR")).toBe(DIAL_DRAG_DIVISOR);
    expect(emulatorHookConstant("PRESS_THRESHOLD_DEG")).toBe(PRESS_THRESHOLD_DEGREES);
  });

  it("full 270° sweep maps to value 100 via applyDragDelta", () => {
    expect(applyDragDelta(0, DIAL_SWEEP_DEGREES)).toBe(100);
  });

  it("full reverse 270° sweep maps to value 0 via applyDragDelta", () => {
    expect(applyDragDelta(100, -DIAL_SWEEP_DEGREES)).toBe(0);
  });

  it("drag divisor: 2.7 deg = 1 value unit", () => {
    expect(applyDragDelta(0, DIAL_DRAG_DIVISOR)).toBeCloseTo(1, 5);
  });

  it("step of 4 applied by applyStep", () => {
    expect(applyStep(50, 1) - 50).toBe(DIAL_STEP);
  });

  it("press threshold: 7.9 deg is a press, 8 deg is not", () => {
    expect(isPress(PRESS_THRESHOLD_DEGREES - 0.1)).toBe(true);
    expect(isPress(PRESS_THRESHOLD_DEGREES)).toBe(false);
  });

  it("value range 0–100", () => {
    expect(clampDial(DIAL_MIN)).toBe(0);
    expect(clampDial(DIAL_MAX)).toBe(100);
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

  it("clamps out-of-range values — 200 is treated as 100", () => {
    expect(dialRotationCss(200)).toBe("135deg");
  });

  it("clamps out-of-range values — -50 is treated as 0", () => {
    expect(dialRotationCss(-50)).toBe("-135deg");
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

  it("accumulates correctly — 100 one-degree moves equal one 100-degree move", () => {
    let v = 0;
    for (let i = 0; i < 100; i++) v = applyDragDelta(v, 1);
    expect(v).toBeCloseTo(applyDragDelta(0, 100), 5);
  });

  it("accumulates correctly with fractional steps — 77 × 1.3° moves equal one 100.1° move", () => {
    let v = 0;
    for (let i = 0; i < 77; i++) v = applyDragDelta(v, 1.3);
    expect(v).toBeCloseTo(applyDragDelta(0, 77 * 1.3), 5);
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
// Dial press / turn router
// ---------------------------------------------------------------------------

describe("dialPressAction", () => {
  it("dial 0 returns BACK", () => {
    expect(dialPressAction(0)).toBe("BACK");
  });

  it("dial 1 returns null (no press action)", () => {
    expect(dialPressAction(1)).toBeNull();
  });

  it("dial 2 returns null (no press action)", () => {
    expect(dialPressAction(2)).toBeNull();
  });

  it("dial 3 returns cycle", () => {
    expect(dialPressAction(3)).toBe("cycle");
  });
});

describe("dial3TurnOffset", () => {
  it("dispatches to columnOffsetFromDial in grid mode", () => {
    expect(dial3TurnOffset(100, "grid", 32)).toBe(columnOffsetFromDial(100, 32));
    expect(dial3TurnOffset(50, "grid", 32)).toBe(columnOffsetFromDial(50, 32));
  });

  it("dispatches to columnOffsetFromDial in cmd mode", () => {
    expect(dial3TurnOffset(100, "cmd", 32)).toBe(columnOffsetFromDial(100, 32));
  });

  it("dispatches to eventOffsetFromDial in logs mode", () => {
    expect(dial3TurnOffset(100, "logs", 20)).toBe(eventOffsetFromDial(100, 20));
    expect(dial3TurnOffset(50, "logs", 20)).toBe(eventOffsetFromDial(50, 20));
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

  it("clamps out-of-range dial values — -1 and 101 stay within valid offset", () => {
    const count = 32;
    expect(columnOffsetFromDial(-1, count)).toBe(0);
    expect(columnOffsetFromDial(101, count)).toBe(maxColumnOffset(count));
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

  it("returns 0 for negative columnOffset (clamp guard)", () => {
    expect(currentWindow(-1, 32)).toBe(0);
    expect(currentWindow(-100, 32)).toBe(0);
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

  it("sync without rotating — round-trip invariant: columnOffsetFromDial(dial3Value) === columnOffset", () => {
    for (const n of [0, 1, 8, 9, 17, 32]) {
      const { columnOffset, dial3Value } = cycleWindow(0, n);
      expect(columnOffsetFromDial(dial3Value, n)).toBe(columnOffset);
    }
  });

  it("returns to window 0 within windowCount presses for all agentCounts 0..40", () => {
    for (let n = 0; n <= 40; n++) {
      const count = windowCount(n);
      let offset = 0;
      for (let i = 0; i < count; i++) {
        ({ columnOffset: offset } = cycleWindow(offset, n));
      }
      expect(offset).toBe(0);
    }
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

  it("clamps out-of-range dial values — -1 and 101 stay within valid offset", () => {
    expect(eventOffsetFromDial(-1, 20)).toBe(0);
    expect(eventOffsetFromDial(101, 20)).toBe(maxEventOffset(20));
  });
});

describe("cycleEventPage", () => {
  it("advances to the next event page and back-computes dial value", () => {
    // 20 total keys (19 events + pinned LIVE): pages of 7 events; maxEventOffset = 12
    const result = cycleEventPage(0, 20);
    expect(result.eventOffset).toBe(7);
    expect(result.dial3Value).toBe(dial3ValueFromEventOffset(7, 20));
  });

  it("wraps from clamped final offset back to offset 0", () => {
    // 20 events: maxEventOffset = 12 (not 16 — 16 is unreachable).
    // Cycling from offset 12 must wrap to 0, not stay stuck at 12.
    const result = cycleEventPage(12, 20);
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

  it("clamps negative currentEventOffset to 0 before advancing", () => {
    // Negative offset should behave as offset 0 — advance one page (7 events), not a phantom page.
    const result = cycleEventPage(-1, 20);
    expect(result.eventOffset).toBe(7);
    expect(result.dial3Value).toBe(dial3ValueFromEventOffset(7, 20));
  });

  it("mid-page offset triggers Math.min clamping — advance from 5 clamps at maxEventOffset 12", () => {
    // min(5 + 7, 12) = 12
    const result = cycleEventPage(5, 20);
    expect(result.eventOffset).toBe(12);
    expect(result.dial3Value).toBe(100);
  });

  it("sync without rotating — round-trip invariant: eventOffsetFromDial(dial3Value) === eventOffset", () => {
    for (const n of [0, 8, 9, 16, 20, 100]) {
      const { eventOffset, dial3Value } = cycleEventPage(0, n);
      expect(eventOffsetFromDial(dial3Value, n)).toBe(eventOffset);
    }
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
  it("returns all four dial rotations set to zero", () => {
    expect(resetDials()).toEqual({
      dial0Rotation: 0,
      dial1Rotation: 0,
      dial2Rotation: 0,
      dial3Rotation: 0,
    });
  });

  it("result satisfies ModeDialState (compile-time via _assertDialResetSatisfiesModeDialState)", () => {
    const result = resetDials();
    // Structural check: assign to ModeDialState — type error if fields diverge.
    const _modeDialState: ModeDialState = result;
    void _modeDialState;
    expect(result.dial0Rotation).toBe(0);
    expect(result.dial3Rotation).toBe(0);
  });

  it("_assertDialResetSatisfiesModeDialState returns the input as ModeDialState", () => {
    const result = resetDials();
    expect(_assertDialResetSatisfiesModeDialState(result)).toBe(result);
  });
});
