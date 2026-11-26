import { decodeInputReport } from "./input.js";

export interface RawInput {
  readonly kind: "key" | "dial" | "touch";
  readonly index: number;
  readonly action: "down" | "up" | "turn" | "press" | "long_press" | "tap";
  readonly delta?: number;
  readonly x?: number;
}

/** Edge tracking and hold classification only; navigation belongs to Aiur. */
export function createFrameInput(send: (input: RawInput) => void, now: () => number = Date.now) {
  const pressed = new Map<string, number>();
  return {
    reset: () => pressed.clear(),
    handleReport: (report: Uint8Array): void => {
      // Plus touch report: gesture byte at 4, little-endian x at 6.
      if (report[0] === 1 && report[1] === 2 && report.length >= 10) {
        const x = report[6]! | (report[7]! << 8);
        if (report[4] === 0 && x < 800) send({ kind: "touch", index: Math.floor(x / 200), action: "tap", x });
        return;
      }
      for (const event of decodeInputReport(report)) {
        if (event.type === "encoder-turn") {
          if (event.ticks !== 0) send({ kind: "dial", index: event.index, action: "turn", delta: event.ticks });
          continue;
        }
        const kind = event.type === "key" ? "key" : "dial";
        const id = `${kind}:${event.index}`;
        const started = pressed.get(id);
        if (event.pressed && started === undefined) {
          pressed.set(id, now());
          send({ kind, index: event.index, action: "down" });
        } else if (!event.pressed && started !== undefined) {
          pressed.delete(id);
          send({ kind, index: event.index, action: "up" });
          if (kind === "dial") send({ kind, index: event.index, action: now() - started >= 500 ? "long_press" : "press" });
        }
      }
    },
  };
}
