
import { readFileSync } from "node:fs";
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
  dial3TurnOffset,
  dialPressAction,
  dialRotationCss,
  eventOffsetFromDial,
  isPress,
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

