/** Encoded HID input reports, shared by the tests that drive the controller. */

/** A key report with one key held or released. */
export const keyReport = (index: number, pressed: boolean): Uint8Array => {
  const report = new Uint8Array(12);
  report[0] = 1;
  report[4 + index] = pressed ? 1 : 0;
  return report;
};

/** A key report with several keys in the same state at once. */
export const keysReport = (indices: readonly number[], pressed: boolean): Uint8Array => {
  const report = new Uint8Array(12);
  report[0] = 1;
  for (const index of indices) report[4 + index] = pressed ? 1 : 0;
  return report;
};

/** An encoder-button report with several knobs held down at once. */
export const dialButtons = (indices: readonly number[], pressed = true): Uint8Array => {
  const report = new Uint8Array(10);
  report[0] = 1;
  report[1] = 3;
  report[4] = 0;
  for (const index of indices) report[5 + index] = pressed ? 1 : 0;
  return report;
};

export const dialButton = (index: number, pressed = true): Uint8Array => dialButtons([index], pressed);

/** An encoder-turn report of `ticks` detents on one knob. */
export const dialTurn = (index: number, ticks: number): Uint8Array => {
  const report = new Uint8Array(10);
  report[0] = 1;
  report[1] = 3;
  report[4] = 1;
  report[5 + index] = ticks;
  return report;
};
