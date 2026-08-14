/**
 * Opt-in diagnostic tracing for the sidecar.
 *
 * The sidecar runs headless under systemd, so when the deck misbehaves the only
 * evidence an operator has is `journalctl --user -u aiur-streamdeck`. Normal
 * operation must stay quiet there — an input trace at 20 reports/second would
 * bury the lifecycle warnings that actually matter — but a silent hot path is
 * exactly what let the input transport bug hide: every key press was being
 * discarded with nothing written anywhere.
 *
 * Setting `AIUR_STREAMDECK_DEBUG=1` turns on a structured trace of the paths
 * that have no other observable output: raw input reports, decoded controls,
 * controller state transitions, channel payloads, and repaint outcomes. It is
 * off by default and costs one closure call returning `undefined` when off.
 */

/** A tracer. Calling it is a no-op unless debug tracing is enabled. */
export type DebugLog = (channel: string, detail?: Record<string, unknown>) => void;

/** Bytes of a raw report rendered in the trace before it is elided. */
const HEX_PREVIEW_BYTES = 16;

/** Renders the leading bytes of a report as space-separated hex. */
export const hexPreview = (bytes: Uint8Array, limit: number = HEX_PREVIEW_BYTES): string => {
  const head = Array.from(bytes.subarray(0, limit))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join(" ");
  return bytes.length > limit ? `${head} …(${bytes.length}B)` : head;
};

/** Formats one detail value compactly; strings stay bare, objects become JSON. */
const formatValue = (value: unknown): string =>
  typeof value === "string"
    ? value
    : typeof value === "object" && value !== null
      ? JSON.stringify(value)
      : String(value);

/**
 * Builds a tracer. `enabled` normally comes from the environment; tests pass it
 * explicitly. `sink` defaults to `console.debug` so tracing goes to stderr and
 * never interleaves with the operator-facing log stream.
 */
export const createDebugLog = (
  enabled: boolean,
  sink: (line: string) => void = (line) => console.debug(line),
): DebugLog => {
  if (!enabled) {
    return () => undefined;
  }
  return (channel, detail) => {
    const fields = Object.entries(detail ?? {})
      .map(([key, value]) => `${key}=${formatValue(value)}`)
      .join(" ");
    sink(`[streamdeck:debug] ${channel}${fields === "" ? "" : ` ${fields}`}`);
  };
};

/** True when the environment asks for tracing. */
export const debugEnabled = (value: string | undefined): boolean => value === "1" || value === "true";
