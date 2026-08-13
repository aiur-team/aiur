/** Stream Deck + input report decoding and edge filtering. */

export type DeckInput =
  | { readonly type: "key"; readonly index: number; readonly pressed: boolean }
  | { readonly type: "encoder-button"; readonly index: number; readonly pressed: boolean }
  | { readonly type: "encoder-turn"; readonly index: number; readonly ticks: number };

/**
 * Decodes the official Stream Deck + report layout. The three-byte prefix
 * before offset 0x04 is part of the HID report, not an application payload;
 * keeping the offsets here prevents the common report-ID stripping bug.
 */
export const decodeInputReport = (report: Uint8Array): DeckInput[] => {
  if (report.length < 5 || report[0] !== 0x01) return [];
  const command = report[1];
  if (command === 0x00) {
    return Array.from({ length: Math.min(8, report.length - 4) }, (_, index) => ({
      type: "key" as const,
      index,
      pressed: report[index + 4] === 1,
    }));
  }
  if (command !== 0x03 || report.length < 6) return [];
  const kind = report[4];
  if (kind === 0x00 || kind === 0x01) {
    return Array.from({ length: Math.min(4, report.length - 5) }, (_, index) => ({
      type: kind === 0x00 ? ("encoder-button" as const) : ("encoder-turn" as const),
      index,
      ...(kind === 0x00 ? { pressed: report[index + 5] === 1 } : { ticks: new DataView(report.buffer, report.byteOffset + index + 5, 1).getInt8(0) }),
    })) as DeckInput[];
  }
  return [];
};

/** Emits only button-down edges; held state reports must not repeat controls. */
export const risingEdges = (inputs: readonly DeckInput[], previous: ReadonlySet<string>): {
  readonly events: DeckInput[];
  readonly pressed: ReadonlySet<string>;
} => {
  const next = new Set(previous);
  const events: DeckInput[] = [];
  for (const input of inputs) {
    if (input.type !== "key" && input.type !== "encoder-button") continue;
    const id = `${input.type}:${input.index}`;
    if (input.pressed && !next.has(id)) events.push(input);
    if (input.pressed) next.add(id);
    else next.delete(id);
  }
  return { events, pressed: next };
};
