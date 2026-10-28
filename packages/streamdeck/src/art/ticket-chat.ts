import type { SKRSContext2D } from "@napi-rs/canvas";
import type { StreamDeckChat } from "../channel.js";

/** One entry, inline role glyph, wrapping across the whole ticket strip. */
export const drawTicketChat = (context: SKRSContext2D, width: number, chat: StreamDeckChat | null, now: number): void => {
  context.font = "14px monospace";
  context.fillStyle = "#a6adc8";
  const state = chat?.state ?? "unavailable";
  const age = chat?.observed_at == null ? "age unknown" : `${Math.floor(Math.max(0, now - chat.observed_at) / 1000)}s old`;
  const status: Record<string, string> = {
    not_retained: "Conversation not retained", unavailable: "Conversation unavailable",
    stale: `Conversation stale · ${age}`, restart_unknown: "Conversation state unknown after restart",
    ended: "Conversation ended", known_empty: "No chat yet.",
  };
  const entry = chat?.latest;
  const label = state === "live" ? (entry ? "" : "No chat yet.") : status[state];
  let y = 16;
  if (label) { context.fillText(label, 6, y); y += 17; }
  if (!entry) return;
  const glyph = entry.k === "op" ? "›" : entry.k === "tool" ? "$" : entry.k === "say" ? "●" : "·";
  const text = entry.k === "tool" ? `${entry.name ?? "tool"} ${entry.arg ?? ""} ${entry.res ?? ""}` : entry.text ?? "";
  context.fillStyle = entry.k === "op" ? "#c69bff" : entry.k === "tool" ? "#a6e3a1" : "#9fd0ff";
  let line = "";
  for (const character of `${glyph} ${text}`) {
    if (character === "\n" || context.measureText(line + character).width > width - 12) {
      context.fillText(line, 6, y);
      y += 17;
      line = "";
      if (y > 96) return;
      if (character === "\n") continue;
    }
    line += character;
  }
  if (line) context.fillText(line, 6, y);
};
