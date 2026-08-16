import { describe, expect, it } from "vitest";

import { createTypewriter, TYPING_CHARS_PER_TICK } from "../../src/touchStrip/typewriter.js";
import type { TranscriptRow } from "../../src/channel.js";

const message = (body: string): TranscriptRow => ({ kind: "message", role: "assistant", body, tool: null });
const header = (): TranscriptRow => ({ kind: "event_header", badge: "INFO", body: "x", label: "x", timestamp: null });

/** The visible body of the newest row, after the reveal has clipped it. */
const newest = (rows: readonly TranscriptRow[]): string => {
  const row = rows[rows.length - 1];
  return row !== undefined && row.kind === "message" ? row.body : "";
};

describe("createTypewriter", () => {
  it("reveals a positive number of characters per tick", () => {
    expect(TYPING_CHARS_PER_TICK).toBeGreaterThan(0);
  });

  /**
   * The first snapshot is the transcript as it already is. Typing it out on
   * open would claim the agent said all of it the moment the surface appeared.
   */
  it("adopts the first snapshot whole and does not animate it", () => {
    const typewriter = createTypewriter(2);
    const rows = [message("already said")];
    typewriter.observe(rows, true);
    expect(typewriter.animating()).toBe(false);
    expect(typewriter.tick()).toBe(false);
    expect(typewriter.render(rows)).toBe(rows);
  });

  it("reveals a newly arrived message a few characters at a time", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("first")], true);
    typewriter.observe([message("second message")], true);
    expect(typewriter.animating()).toBe(true);
    expect(newest(typewriter.render([message("second message")]))).toBe("");
    typewriter.tick();
    expect(newest(typewriter.render([message("second message")]))).toBe("se");
    typewriter.tick();
    expect(newest(typewriter.render([message("second message")]))).toBe("seco");
  });

  it("finishes on the whole string and reports that it is done", () => {
    const typewriter = createTypewriter(4);
    typewriter.observe([message("a")], true);
    typewriter.observe([message("abcdef")], true);
    expect(typewriter.tick()).toBe(true);
    expect(typewriter.tick()).toBe(false);
    expect(typewriter.animating()).toBe(false);
    expect(newest(typewriter.render([message("abcdef")]))).toBe("abcdef");
  });

  /**
   * The bug this guards: a finished reveal that forgets what it finished sees
   * the next unchanged snapshot as a brand-new message, and the row types
   * itself out forever.
   */
  it("does not restart on an unchanged body it has already finished", () => {
    const typewriter = createTypewriter(4);
    typewriter.observe([message("a")], true);
    typewriter.observe([message("abcdef")], true);
    while (typewriter.tick()) {
      /* drain */
    }
    typewriter.observe([message("abcdef")], true);
    expect(typewriter.animating()).toBe(false);
  });

  /**
   * Providers re-send a growing body for the same row. Treating that as a new
   * message rewinds the reveal and the row visibly stutters.
   */
  it("resumes rather than restarting when the same row grows", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("a")], true);
    typewriter.observe([message("abcdefgh")], true);
    typewriter.tick();
    typewriter.tick();
    expect(newest(typewriter.render([message("abcdefgh")]))).toBe("abcde");
    typewriter.observe([message("abcdefghijkl")], true);
    expect(newest(typewriter.render([message("abcdefghijkl")]))).toBe("abcde");
    expect(typewriter.animating()).toBe(true);
  });

  it("stops and adopts the whole body when the operator scrolls away from live", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("a")], true);
    typewriter.observe([message("a longer body")], true);
    expect(typewriter.animating()).toBe(true);
    typewriter.observe([message("a longer body")], false);
    expect(typewriter.animating()).toBe(false);
    expect(typewriter.render([message("a longer body")])).toEqual([message("a longer body")]);
  });

  // Only the agent's own prose types. A header or a diff at the tail is not
  // something anyone was in the middle of writing.
  it("never animates a tail row that is not a message", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("a")], true);
    typewriter.observe([message("a"), header()], true);
    expect(typewriter.animating()).toBe(false);
    expect(typewriter.tick()).toBe(false);
  });

  it("handles an empty history without animating", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([], true);
    expect(typewriter.animating()).toBe(false);
    expect(typewriter.render([])).toEqual([]);
  });

  /**
   * Switching to a different agent has to reset the never-type-out-history
   * rule too, or the new agent's transcript would type itself out on arrival —
   * the first snapshot of *that* agent is still a first snapshot.
   */
  it("forgets everything, including that a first snapshot was seen", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("agent A said this")], true);
    typewriter.observe([message("and then this, at some length")], true);
    expect(typewriter.animating()).toBe(true);

    typewriter.forget();
    expect(typewriter.animating()).toBe(false);

    const fresh = [message("agent B's existing transcript")];
    typewriter.observe(fresh, true);
    expect(typewriter.animating()).toBe(false);
    expect(typewriter.render(fresh)).toBe(fresh);
  });

  /**
   * The reveal indexes into the history it last saw. A shorter history can
   * arrive before the next `observe` — a refresh that dropped rows — so
   * `render` must leave it alone rather than clip a row that is not there.
   */
  it("leaves a history that no longer holds the animated row untouched", () => {
    const typewriter = createTypewriter(2);
    typewriter.observe([message("a"), message("b")], true);
    typewriter.observe([message("a"), message("a much longer second row")], true);
    expect(typewriter.animating()).toBe(true);
    const shorter = [message("a")];
    expect(typewriter.render(shorter)).toBe(shorter);
    const replaced = [message("a"), header()];
    expect(typewriter.render(replaced)).toBe(replaced);
  });
});
