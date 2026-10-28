import type { SpawnLike } from "../line-source.js";

export const ticketAction = (index: number, transcript: boolean): string | undefined =>
  ["pause", "priority_up", "priority_down", "commands", transcript ? "send" : "pr", transcript ? "cancel" : "modal", "mic", "settings"][index];

export const openTicketLink = (url: string | null | undefined, spawn?: SpawnLike, onError?: (reason: string) => void): void => {
  if (!url || !spawn) return;
  try {
    if (!["http:", "https:"].includes(new URL(url).protocol)) return;
    const child = spawn("xdg-open", [url]);
    child.on("error", (reason) => onError?.(String(reason)));
    child.on("close", (code) => { if (code) onError?.(`xdg-open exited ${String(code)}`); });
  } catch (error) {
    onError?.(String(error));
  }
};
