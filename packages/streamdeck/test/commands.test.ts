import { describe, expect, it } from "vitest";

import type { StreamDeckCommand, StreamDeckCommandsPage } from "../src/channel.js";
import {
  activeCommandCount,
  clampHistoryOffset,
  clampOptionOffset,
  commandDescription,
  commandIdempotencyKey,
  commandOutcomeLabel,
  commandStatusLabel,
  COMMANDS_APPROVE_SLOT,
  COMMANDS_CANCEL_SLOT,
  COMMANDS_MIC_SLOT,
  COMMANDS_MORE_SLOT,
  detailKeyDescriptors,
  detailPanel,
  hasMoreHistory,
  hasMoreOptions,
  historyKeyDescriptors,
  historyPageLabel,
  historyPanel,
  HISTORY_PER_PAGE,
  isAnswerable,
  isAnswered,
  maxHistoryOffset,
  maxOptionOffset,
  optionPageLabel,
  OPTIONS_PER_PAGE,
} from "../src/commands.js";

const openCommand = (overrides: Partial<StreamDeckCommand> = {}): StreamDeckCommand => ({
  decision_id: "dec-1",
  version: 3,
  ticket: { identifier: "AIUR-1" },
  question: "Ship the change?",
  context: { short: "The checks are green." },
  options: [
    { id: "ship", label: "Ship it", description: "Merge and deploy now." },
    { id: "wait", label: "Wait", description: "Hold until tomorrow." },
    { id: "split", label: "Split", description: "Land in two smaller PRs." },
    { id: "revert", label: "Revert", description: "Back it out." },
    { id: "ask", label: "Ask the owner", description: "Escalate upstream." },
    { id: "park", label: "Park", description: "Defer indefinitely." },
    { id: "run", label: "Run again", description: "Rerun the pipeline." },
  ],
  status: "open",
  blocking: true,
  answer: null,
  created_at: "2026-08-18T00:00:00Z",
  ...overrides,
});

const answeredCommand = (overrides: Partial<StreamDeckCommand> = {}): StreamDeckCommand =>
  openCommand({
    status: "decided",
    answer: { selected_option_id: "ship", actor: { kind: "operator", id: "streamdeck" } },
    ...overrides,
  });

const page = (items: readonly StreamDeckCommand[]): StreamDeckCommandsPage => ({ items });

describe("Commands answerability", () => {
  it("answers only open or deferred Commands", () => {
    expect(isAnswerable("open")).toBe(true);
    expect(isAnswerable("deferred")).toBe(true);
    expect(isAnswerable("decided")).toBe(false);
    expect(isAnswerable("acknowledged")).toBe(false);
    expect(isAnswerable("resolved")).toBe(false);
    expect(isAnswerable("dismissed")).toBe(false);
    expect(isAnswerable("expired")).toBe(false);
  });

  it("treats completed Commands as read-only", () => {
    expect(isAnswered("decided")).toBe(true);
    expect(isAnswered("open")).toBe(false);
  });
});

describe("Commands paging", () => {
  it("clamps history offsets into the window", () => {
    expect(maxHistoryOffset(12)).toBe(4);
    expect(clampHistoryOffset(9, 12)).toBe(4);
    expect(clampHistoryOffset(-3, 12)).toBe(0);
    expect(clampHistoryOffset(2, 12)).toBe(2);
  });

  it("clamps option offsets into the window", () => {
    expect(maxOptionOffset(7)).toBe(3);
    expect(clampOptionOffset(99, 7)).toBe(3);
    expect(clampOptionOffset(-1, 7)).toBe(0);
    expect(clampOptionOffset(1, 7)).toBe(1);
  });

  it("reports more history or options beyond the window", () => {
    expect(hasMoreHistory(0, 12)).toBe(true);
    expect(hasMoreHistory(4, 12)).toBe(false);
    expect(hasMoreOptions(0, 7)).toBe(true);
    expect(hasMoreOptions(3, 7)).toBe(false);
  });

  it("labels pages as 1/1 until there is more than one", () => {
    expect(historyPageLabel(0, 8)).toBe("");
    expect(historyPageLabel(0, 20)).toBe("1/3");
    expect(historyPageLabel(8, 20)).toBe("2/3");
    expect(optionPageLabel(0, 4)).toBe("");
    expect(optionPageLabel(0, 7)).toBe("1/2");
  });
});

describe("Commands status labels", () => {
  it("labels each lifecycle for the operator", () => {
    expect(commandStatusLabel("open")).toBe("OPEN");
    expect(commandStatusLabel("deferred")).toBe("DEFERRED");
    expect(commandStatusLabel("decided")).toBe("ANSWERED");
    expect(commandStatusLabel("acknowledged")).toBe("ANSWERED");
    expect(commandStatusLabel("resolved")).toBe("ANSWERED");
    expect(commandStatusLabel("dismissed")).toBe("CLOSED");
    expect(commandStatusLabel("expired")).toBe("CLOSED");
    expect(commandStatusLabel("weird")).toBe("WEIRD");
    expect(commandStatusLabel(null)).toBe("UNKNOWN");
  });

  it("names the recorded outcome of an answered Command", () => {
    expect(commandOutcomeLabel(answeredCommand())).toBe("Chose: Ship it");
    expect(commandOutcomeLabel(answeredCommand({ answer: { custom_response: "Hold everything" } }))).toBe("Spoken: Hold everything");
    expect(commandOutcomeLabel(answeredCommand({ answer: { selected_option_id: "missing" } }))).toBe("Option chosen");
    expect(commandOutcomeLabel(answeredCommand({ answer: {} }))).toBe("Answered");
    expect(commandOutcomeLabel(openCommand())).toBeNull();
  });
});

describe("Commands history keys", () => {
  it("paints the window newest-first with an OPEN badge for active Commands", () => {
    const keys = historyKeyDescriptors(page([openCommand(), answeredCommand()]), 0, null);
    expect(keys).toHaveLength(HISTORY_PER_PAGE);
    expect(keys[0]).toMatchObject({ title: "Ship the change?", subLabel: "OPEN", icon: "question", role: "event" });
    expect(keys[1]).toMatchObject({ subLabel: "ANSWERED", icon: "check", role: "event" });
    expect(keys[2]).toBeUndefined();
  });

  it("honours the selection with the shared event idiom", () => {
    const keys = historyKeyDescriptors(page([openCommand()]), 0, 0);
    expect(keys[0]).toMatchObject({ selected: true });
  });

  it("clamps the window so a pressed offset addresses the painted key", () => {
    const items = Array.from({ length: 12 }, (_, index) => openCommand({ decision_id: `dec-${index}`, question: `Q${index}` }));
    const keys = historyKeyDescriptors(page(items), 9, 9);
    // offset 9 clamps to 4; key 5 is item 9.
    expect(keys[5]).toMatchObject({ title: "Q9" });
  });
});

describe("Commands detail keys", () => {
  it("paints options, then the always-present mic, for an answerable Command", () => {
    const keys = detailKeyDescriptors(openCommand(), 0, null, false, false);
    expect(keys.slice(0, OPTIONS_PER_PAGE)).toEqual([
      expect.objectContaining({ title: "Ship it", subLabel: "OPT 1", role: "event" }),
      expect.objectContaining({ title: "Wait", subLabel: "OPT 2" }),
      expect.objectContaining({ title: "Split", subLabel: "OPT 3" }),
      expect.objectContaining({ title: "Revert", subLabel: "OPT 4" }),
    ]);
    expect(keys[COMMANDS_MIC_SLOT]).toMatchObject({ title: "Mic", icon: "mic", subLabel: "HOLD" });
    expect(keys[COMMANDS_APPROVE_SLOT]).toBeUndefined();
    expect(keys[COMMANDS_MORE_SLOT]).toMatchObject({ title: "More", icon: "next" });
  });

  it("selects an option for reading with the shared event idiom and never commits", () => {
    const keys = detailKeyDescriptors(openCommand(), 0, 2, false, false);
    expect(keys[2]).toMatchObject({ selected: true, role: "event" });
  });

  it("adds green Approve and Cancel only while the dictation buffer holds text", () => {
    const keys = detailKeyDescriptors(openCommand(), 0, null, false, true);
    expect(keys[COMMANDS_APPROVE_SLOT]).toMatchObject({ title: "Approve", icon: "approve", subLabel: "SEND", bucket: "running" });
    expect(keys[COMMANDS_CANCEL_SLOT]).toMatchObject({ title: "Cancel", icon: "cancel", subLabel: "DISCARD" });
  });

  it("turns the mic live while held", () => {
    const keys = detailKeyDescriptors(openCommand(), 0, null, true, false);
    expect(keys[COMMANDS_MIC_SLOT]).toMatchObject({ subLabel: "LIVE" });
  });

  it("is read-only for a completed Command: no mic, Approve, Cancel or paging", () => {
    const keys = detailKeyDescriptors(answeredCommand(), 0, null, false, false);
    expect(keys[COMMANDS_MIC_SLOT]).toBeUndefined();
    expect(keys[COMMANDS_APPROVE_SLOT]).toBeUndefined();
    expect(keys[COMMANDS_CANCEL_SLOT]).toBeUndefined();
    expect(keys[COMMANDS_MORE_SLOT]).toBeUndefined();
  });

  it("pages options and hides the paging key when no options overflow", () => {
    const few = openCommand({ options: openCommand().options.slice(0, 3) });
    const keys = detailKeyDescriptors(few, 0, null, false, false);
    expect(keys[COMMANDS_MORE_SLOT]).toBeUndefined();
    // Seven options, four per page: the second page starts at the clamped
    // offset 3 and shows the last four options.
    const paged = detailKeyDescriptors(openCommand(), 4, null, false, false);
    expect(paged[0]).toMatchObject({ title: "Revert", subLabel: "OPT 4" });
    expect(paged[3]).toMatchObject({ title: "Run again", subLabel: "OPT 7" });
  });
});

describe("Commands description", () => {
  it("reads the Command's own description by default", () => {
    expect(commandDescription(openCommand(), null)).toBe("The checks are green.");
  });

  it("reads the selected option's detail when one is selected", () => {
    expect(commandDescription(openCommand(), 0)).toBe("Merge and deploy now.");
  });

  it("joins an option's cost and benefit parts when present", () => {
    const withDetail = openCommand({
      options: [{ id: "ship", label: "Ship it", description: "Merge.", benefits: "Unblocks the team.", drawbacks: "Risky.", risk: "Low." }],
    });
    expect(commandDescription(withDetail, 0)).toBe("Merge. · Unblocks the team. · Risky. · Low.");
  });

  it("drops an empty option part instead of joining it", () => {
    const withEmpty = openCommand({ options: [{ id: "ship", label: "Ship it", description: "", benefits: "Fast." }] });
    expect(commandDescription(withEmpty, 0)).toBe("Fast.");
  });

  it("falls back when neither the Command nor the option has a description", () => {
    const bare = openCommand({ context: { short: "" }, options: [{ id: "x", label: "X" }] });
    expect(commandDescription(bare, 0)).toBe("No description");
  });

  it("reads the Command description when the selected option index is out of range", () => {
    expect(commandDescription(openCommand(), 99)).toBe("The checks are green.");
  });
});

describe("Commands idempotency keys", () => {
  it("derives a stable key from the Command and the answer content", () => {
    const first = commandIdempotencyKey("dec-1", { option_id: "ship" });
    const second = commandIdempotencyKey("dec-1", { option_id: "ship" });
    expect(first).toBe(second);
    expect(commandIdempotencyKey("dec-1", { option_id: "wait" })).not.toBe(first);
    expect(commandIdempotencyKey("dec-2", { option_id: "ship" })).not.toBe(first);
  });

  it("uses the custom response content when present", () => {
    expect(commandIdempotencyKey("dec-1", { custom_response: "Hold everything" })).toBe(
      commandIdempotencyKey("dec-1", { custom_response: "Hold everything" }),
    );
    expect(commandIdempotencyKey("dec-1", { custom_response: "Hold" })).not.toBe(
      commandIdempotencyKey("dec-1", { custom_response: "Hold everything" }),
    );
  });

  it("falls back to a stable key when neither option nor response is present", () => {
    expect(commandIdempotencyKey("dec-1", {})).toBe(commandIdempotencyKey("dec-1", {}));
  });
});

describe("Commands panels", () => {
  it("counts the open Commands on a page", () => {
    expect(activeCommandCount(page([openCommand(), answeredCommand(), openCommand()]))).toBe(2);
  });

  it("builds the history strip with the open count and page position", () => {
    const panel = historyPanel({ ...page([openCommand(), answeredCommand()]), total: 12 }, 0, "AIUR-1");
    expect(panel).toMatchObject({
      view: "history",
      ticketId: "AIUR-1",
      activeCount: 1,
      total: 12,
      title: "Commands",
      description: "1 awaiting your answer",
      status: "OPEN",
    });
  });

  it("says when the agent has no open Commands", () => {
    const panel = historyPanel(page([answeredCommand()]), 0, "AIUR-1");
    expect(panel).toMatchObject({ activeCount: 0, description: "No open Commands", status: "CLEAR" });
  });

  it("says the Commands are unavailable when the store could not be read", () => {
    const panel = historyPanel({ items: [], unavailable: true }, 0, "AIUR-1");
    expect(panel).toMatchObject({ activeCount: 0, description: "Commands unavailable", status: "UNAVAILABLE" });
  });

  it("builds the detail strip answerable with the approval state", () => {
    const panel = detailPanel(openCommand(), 0, false);
    expect(panel).toMatchObject({
      view: "detail",
      title: "Ship the change?",
      description: "Merge and deploy now.",
      status: "OPEN",
      answerable: true,
      approving: true,
      recorded: null,
    });
  });

  it("arms approval for dictation even without a selected option", () => {
    const panel = detailPanel(openCommand(), null, true);
    expect(panel.approving).toBe(true);
  });

  it("builds the detail strip read-only with the recorded outcome", () => {
    const panel = detailPanel(answeredCommand(), null, false);
    expect(panel).toMatchObject({
      answerable: false,
      approving: false,
      status: "ANSWERED",
      recorded: "Chose: Ship it",
    });
  });

  it("handles a Command without a ticket identifier", () => {
    const panel = detailPanel(openCommand({ ticket: undefined }), null, false);
    expect(panel.ticketId).toBe("");
  });
});
