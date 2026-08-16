/**
 * Pure dial semantics and paging math for the Stream Deck + four-dial layout.
 *
 * No device, DOM, timer, or network dependency. All functions are referentially
 * transparent and suitable for unit testing in CI.
 *
 * Dial assignment:
 *   0 (A) – in logs: scroll transcript/chat;  press = BACK
 *   1 (B) – free-rotating, unassigned;         press = none
 *   2 (C) – free-rotating, unassigned;         press = none
 *   3 (D) – in grid: page columns; in logs: scroll events; press = cycle window/page
 */

import type { ModeDialState, StreamDeckMode } from "./mode.js";

// ---------------------------------------------------------------------------
// Value range constants
// ---------------------------------------------------------------------------

/** Inclusive value range for every dial. */
export const DIAL_MIN = 0;
export const DIAL_MAX = 100;

/** Full physical sweep in degrees. */
export const DIAL_SWEEP_DEGREES = 270;

/**
 * Converts an emulator pointer-drag delta (degrees) to a dial value delta.
 * delta_degrees / 2.7  →  value delta (unrounded, caller rounds as needed).
 */
export const DIAL_DRAG_DIVISOR = 2.7;

/** Step applied by wheel events and keyboard arrow keys. */
export const DIAL_STEP = 4;

/**
 * Accumulated absolute rotation threshold (degrees) distinguishing a press
 * from a turn.  Below → press;  at or above → turn.
 */
export const PRESS_THRESHOLD_DEGREES = 8;

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

export const clampDial = (value: number): number => Math.max(DIAL_MIN, Math.min(DIAL_MAX, value));

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/**
 * CSS `rotate` value for the physical knob given a 0–100 dial value.
 * The resting position (value 0) is –135 deg; value 100 is +135 deg.
 * Input is clamped so out-of-range stored values never produce bogus CSS.
 */
export const dialRotationCss = (value: number): string =>
  `${-135 + (clampDial(value) / 100) * DIAL_SWEEP_DEGREES}deg`;

// ---------------------------------------------------------------------------
// Drag and step helpers
// ---------------------------------------------------------------------------

/**
 * Applies a drag-delta (degrees) to an existing dial value.
 * Returns a float — round only at render time so that many small pointer
 * moves accumulate correctly instead of rounding to zero.
 */
export const applyDragDelta = (currentValue: number, deltaDegrees: number): number =>
  clampDial(currentValue + deltaDegrees / DIAL_DRAG_DIVISOR);

/**
 * Applies a wheel or keyboard-arrow step (+1 or –1 multiplied by DIAL_STEP).
 */
export const applyStep = (currentValue: number, direction: 1 | -1): number =>
  clampDial(currentValue + direction * DIAL_STEP);

// ---------------------------------------------------------------------------
// Press vs. turn discrimination
// ---------------------------------------------------------------------------

/**
 * Returns true when the accumulated absolute rotation is below the press
 * threshold — i.e., the gesture was a press, not a turn.
 */
export const isPress = (accumulatedAbsRotationDegrees: number): boolean =>
  accumulatedAbsRotationDegrees < PRESS_THRESHOLD_DEGREES;

// ---------------------------------------------------------------------------
// Dial press / turn router
// ---------------------------------------------------------------------------

/**
 * The action produced by pressing a dial.
 *   0 → BACK
 *   1 → null (free-rotating; no press action)
 *   2 → null (free-rotating; no press action)
 *   3 → cycle (cycle window in grid mode, cycle event page in logs mode)
 */
export type DialPressAction = "BACK" | "cycle" | null;

export const dialPressAction = (dialIndex: 0 | 1 | 2 | 3): DialPressAction => {
  if (dialIndex === 0) return "BACK";
  if (dialIndex === 3) return "cycle";
  return null;
};

/**
 * The column or event offset produced by turning dial 3, dispatched by mode.
 * Pass agentCount for grid/cmd and eventCount for logs.
 */
export const dial3TurnOffset = (
  dial3Value: number,
  mode: StreamDeckMode,
  count: number,
): number =>
  mode === "logs" ? eventOffsetFromDial(dial3Value, count) : columnOffsetFromDial(dial3Value, count);

// ---------------------------------------------------------------------------
// Paging math — grid mode (dial 3)
// ---------------------------------------------------------------------------

/**
 * Maximum column offset for a given agent count.
 * maxOffset = max(0, ceil(agentCount / 2) − 4)
 */
export const maxColumnOffset = (agentCount: number): number =>
  Math.max(0, Math.ceil(agentCount / 2) - 4);

/**
 * Total number of windows for a given agent count.
 * windowCount = max(1, ceil(agentCount / 8))
 */
export const windowCount = (agentCount: number): number =>
  Math.max(1, Math.ceil(agentCount / 8));

/**
 * Column offset derived from dial 3's value (0–100).
 * dial3Value is clamped before use so out-of-range inputs cannot produce
 * offsets outside [0, maxOffset].
 * offset = round((clamp(dial3Value) / 100) * maxOffset)
 */
export const columnOffsetFromDial = (dial3Value: number, agentCount: number): number =>
  Math.round((clampDial(dial3Value) / 100) * maxColumnOffset(agentCount));

/**
 * The stop position for a window index.
 * stop = min(window * 4, maxOffset)
 */
export const windowStopPosition = (windowIndex: number, agentCount: number): number =>
  Math.min(windowIndex * 4, maxColumnOffset(agentCount));

/**
 * The current window index for a given column offset.
 * Current window = the highest window whose stop position is ≤ columnOffset.
 *
 * O(1) derivation: stopPosition(w) = min(w * 4, maxOffset).
 * - If offset >= maxOffset, every window qualifies → highest = windowCount − 1.
 * - Otherwise offset < maxOffset, so uncapped stops apply: w * 4 ≤ offset → w ≤ floor(offset / 4).
 */
export const currentWindow = (columnOffset: number, agentCount: number): number => {
  const clampedOffset = Math.max(0, columnOffset);
  const maxOff = maxColumnOffset(agentCount);

  if (clampedOffset >= maxOff) return windowCount(agentCount) - 1;

  return Math.min(Math.floor(clampedOffset / 4), windowCount(agentCount) - 1);
};

/**
 * Advances to the next window (cycling back to 0) and returns both the new
 * column offset and the back-computed dial value that matches it — without
 * visually rotating the knob (caller stores both, renders only the offset).
 */
export const cycleWindow = (
  currentColumnOffset: number,
  agentCount: number,
): { columnOffset: number; dial3Value: number } => {
  const count = windowCount(agentCount);
  const current = currentWindow(currentColumnOffset, agentCount);
  const next = (current + 1) % count;
  const offset = windowStopPosition(next, agentCount);

  return { columnOffset: offset, dial3Value: dial3ValueFromOffset(offset, agentCount) };
};

/**
 * Back-computes the dial 3 value from a column offset so that the knob stays
 * in sync with the view after a programmatic offset change (e.g. window cycle).
 */
export const dial3ValueFromOffset = (columnOffset: number, agentCount: number): number => {
  const maxOff = maxColumnOffset(agentCount);

  return maxOff === 0 ? 0 : clampDial(Math.round((columnOffset / maxOff) * 100));
};

// ---------------------------------------------------------------------------
// Paging math — logs mode (dial 3)
// ---------------------------------------------------------------------------

/**
 * Events shown per page in logs mode. LIVE is pinned to the rightmost key and
 * never scrolls, so a page holds this many events (seven) plus the pinned LIVE
 * key — one fewer than the physical eight keys. Paging advances by this many
 * events so a page turn never skips or overlaps one.
 */
export const EVENTS_PER_PAGE = 7;

/**
 * Maximum event page offset in logs mode.
 * `eventCount` is the total key count (events plus the pinned LIVE key), and
 * the bound is `eventCount − 8` because the window is EVENTS_PER_PAGE events
 * plus one pinned LIVE key.
 * bound = max(0, eventCount − 8)
 */
export const maxEventOffset = (eventCount: number): number => Math.max(0, eventCount - 8);

/**
 * Event offset derived from dial 3's value (0–100) in logs mode.
 * dial3Value is clamped before use so out-of-range inputs cannot escape the
 * valid offset range.
 */
export const eventOffsetFromDial = (dial3Value: number, eventCount: number): number =>
  Math.round((clampDial(dial3Value) / 100) * maxEventOffset(eventCount));

/**
 * Cycles to the next event page in logs mode and back-computes the dial value
 * (same sync-without-rotating pattern as grid cycling).
 */
export const cycleEventPage = (
  currentEventOffset: number,
  eventCount: number,
): { eventOffset: number; dial3Value: number } => {
  const maxOff = maxEventOffset(eventCount);

  if (maxOff === 0) return { eventOffset: 0, dial3Value: 0 };

  // Mirror the guard in currentWindow: clamp negative offsets to 0 so stale
  // or out-of-range state never produces a phantom mid-page result.
  const safeOffset = Math.max(0, currentEventOffset);

  // When at or beyond the clamped maximum, wrap back to 0; otherwise advance
  // by one page (EVENTS_PER_PAGE events) and clamp. Using >= maxOff (not a
  // page-number comparison) avoids the stuck-at-last-page bug that occurs when
  // the clamped offset falls mid-page according to floor division.
  const offset = safeOffset >= maxOff ? 0 : Math.min(safeOffset + EVENTS_PER_PAGE, maxOff);

  return { eventOffset: offset, dial3Value: dial3ValueFromEventOffset(offset, eventCount) };
};

/**
 * Back-computes the dial 3 value from an event offset so the knob stays in
 * sync after a programmatic page change.
 */
export const dial3ValueFromEventOffset = (eventOffset: number, eventCount: number): number => {
  const maxOff = maxEventOffset(eventCount);

  return maxOff === 0 ? 0 : clampDial(Math.round((eventOffset / maxOff) * 100));
};

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

/**
 * Result of a reset action. Field names mirror ModeDialState so spreads are
 * type-safe. Dial 3 is included (reset to its back-computed position for
 * offset 0) so callers get a single object covering all four dials.
 *
 * DialResetResult is a structural superset of ModeDialState (adds dial1/dial2
 * which the mode machine does not track). The exported type-level function
 * below enforces at compile time that the superset relationship holds.
 */
export interface DialResetResult {
  dial0Rotation: number;
  dial1Rotation: number;
  dial2Rotation: number;
  dial3Rotation: number;
}

/**
 * Compile-time assertion: DialResetResult must be assignable to ModeDialState.
 * If ModeDialState gains required fields not in DialResetResult, this errors.
 * @internal
 */
export const _assertDialResetSatisfiesModeDialState = (r: DialResetResult): ModeDialState => r;

export const resetDials = (): DialResetResult => ({
  dial0Rotation: 0,
  dial1Rotation: 0,
  dial2Rotation: 0,
  dial3Rotation: 0,
});
