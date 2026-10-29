import type { StreamDeckChat, TranscriptRow } from "../channel.js";
import type { ControllerCore } from "./state.js";
import { createTypewriter } from "../touchStrip/typewriter.js";

/** The first focused frame is history; only subsequent live text animates. */
export const createTicketChat = (core: ControllerCore) => {
  const writer = createTypewriter();
  let current: StreamDeckChat | null = null;
  let rows: readonly TranscriptRow[] = [];
  const publish = () => {
    if (current?.id !== core.state.focusedIdentifier) return;
    const rendered = writer.render(rows)[0];
    const latest = current.latest;
    const chat = latest && rendered?.kind === "message" ? { ...current, latest: { ...latest, text: rendered.body } } : current;
    core.publish({ ...core.state, chat });
  };
  return {
    setChat(chat: StreamDeckChat): void {
      if (chat.id !== core.state.focusedIdentifier) return;
      if (current?.id !== chat.id || core.state.chat == null) writer.forget();
      current = chat;
      const entry = chat.latest;
      rows = entry && entry.k !== "tool" ? [{ kind: "message", role: entry.k === "op" ? "user" : "assistant", body: entry.text ?? "", tool: null }] : [];
      writer.observe(rows, chat.state === "live" && core.state.mode === "cmd");
      publish();
    },
    tickTyping(): boolean {
      if (core.state.mode !== "cmd" || current?.id !== core.state.focusedIdentifier || !writer.animating()) return false;
      const more = writer.tick();
      publish();
      return more;
    },
  };
};
