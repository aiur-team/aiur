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
// Rendering
// ---------------------------------------------------------------------------

/**
 * CSS `rotate` value for the physical knob given a 0–100 dial value.
 * The resting position (value 0) is –135 deg; value 100 is +135 deg.
 */
export const dialRotationCss = (value: number): string =>
  `${-135 + (value / 100) * DIAL_SWEEP_DEGREES}deg`;

// ---------------------------------------------------------------------------
// Value helpers
// ---------------------------------------------------------------------------

export const clampDial = (value: number): number => Math.max(DIAL_MIN, Math.min(DIAL_MAX, value));

/**
 * Applies a drag-delta (degrees) to an existing dial value.
 * Raw pointer drag → divide by DIAL_DRAG_DIVISOR → add to current value → clamp.
 */
export const applyDragDelta = (currentValue: number, deltaDegrees: number): number =>
  clampDial(Math.round(currentValue + deltaDegrees / DIAL_DRAG_DIVISOR));

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
 * offset = round((dial3Value / 100) * maxOffset)
 */
export const columnOffsetFromDial = (dial3Value: number, agentCount: number): number =>
  Math.round((dial3Value / 100) * maxColumnOffset(agentCount));

/**
 * The stop position for a window index.
 * stop = min(window * 4, maxOffset)
 */
export const windowStopPosition = (windowIndex: number, agentCount: number): number =>
  Math.min(windowIndex * 4, maxColumnOffset(agentCount));

/**
 * The current window index for a given column offset.
 * Current window = the highest window whose stop position is ≤ columnOffset.
 */
export const currentWindow = (columnOffset: number, agentCount: number): number => {
  const count = windowCount(agentCount);
  let result = 0;

  for (let w = 0; w < count; w++) {
    if (windowStopPosition(w, agentCount) <= columnOffset) result = w;
  }

  return result;
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
 * Maximum event page offset in logs mode.
 * bound = max(0, eventCount − 8)
 */
export const maxEventOffset = (eventCount: number): number => Math.max(0, eventCount - 8);

/**
 * Event offset derived from dial 3's value (0–100) in logs mode.
 */
export const eventOffsetFromDial = (dial3Value: number, eventCount: number): number =>
  Math.round((dial3Value / 100) * maxEventOffset(eventCount));

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

  // When at or beyond the clamped maximum, wrap back to 0; otherwise advance
  // by one page and clamp. Using >= maxOff (not a page-number comparison) avoids
  // the stuck-at-last-page bug that occurs when the clamped offset falls
  // mid-page according to floor division.
  const offset = currentEventOffset >= maxOff ? 0 : Math.min(currentEventOffset + 8, maxOff);

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
 * Returns the dial values after a reset action.
 * Dials 0–2 return to zero; dial 3 is view-state and is excluded from the
 * return value — callers manage it separately via the offset reset path.
 */
export interface DialResetResult {
  dial0Value: number;
  dial1Value: number;
  dial2Value: number;
}

export const resetDials = (): DialResetResult => ({
  dial0Value: 0,
  dial1Value: 0,
  dial2Value: 0,
});
