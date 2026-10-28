import { afterEach, describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import { detailKeyDescriptors } from "../src/commands.js";
import type { StreamDeckCommand, StreamDeckCommandAnswerError, StreamDeckGrid } from "../src/channel.js";
import { dialButton, keyReport } from "./support/deckReports.js";

const command: StreamDeckCommand = {
  decision_id: "race", version: 3, ticket: { identifier: "agent-0" }, question: "Ship?",
  options: [{ id: "ship", label: "Ship it" }], status: "open", answer: null, created_at: "2026-10-26T00:00:00Z",
};
const grid: StreamDeckGrid = { agents: [{ identifier: "agent-0", bucket: "running", title: "Agent" }], total: 1, windows: 1, max_column_offset: 0 };

const harness = async () => {
  let resolveSent: () => void = () => undefined;
  const sent = new Promise<void>((resolve) => { resolveSent = resolve; });
  const channel = { focus: vi.fn(), control: vi.fn(), say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn(() => resolveSent()) };
  const controller = createPhysicalController({ grid: () => grid, channel: () => channel, stateChanged: vi.fn() });
  const press = (key: number) => { controller.handleReport(keyReport(key, true)); controller.handleReport(keyReport(key, false)); };
  press(0);
  press(4);
  controller.setCommands({ items: [command] });
  press(0);
  press(0);
  controller.handleReport(dialButton(3, true));
  controller.handleReport(dialButton(3, false));
  await sent;
  channel.focus.mockClear();
  return { controller, channel };
};
const keys = (controller: Awaited<ReturnType<typeof harness>>["controller"]) => {
  const state = controller.state();
  return detailKeyDescriptors(state.selectedCommand!, state.optionOffset, state.selectedOption, false, false, state.commandFeedback);
};

afterEach(() => vi.useRealTimers());

describe("answer race feedback", () => {
  it("shows winner on the attempted key across refresh, then removes it", async () => {
    const { controller, channel } = await harness();
    vi.useFakeTimers();
    controller.commandsError("already_answered", { reason: "already_answered", winner: { actor_kind: "operator", summary: "Wait for QA", accepted_at: "2026-10-26T00:00:00Z" } });
    expect(keys(controller)[0]).toMatchObject({ title: "Wait for QA", subLabel: "Answered by operator" });
    expect(channel.focus).toHaveBeenCalledWith("agent-0");
    controller.setCommands({ items: [{ ...command, status: "decided" }] });
    expect(keys(controller)[0]?.title).toBe("Wait for QA");
    expect(controller.state().commandsError).toContain("Answered by operator");
    vi.advanceTimersByTime(3_000);
    expect(keys(controller)[0]?.title).toBe("Ship it");
    expect(controller.state().commandsError).toBeNull();
  });

  it("keeps feedback visible when the refreshed first page omits the attempted Command", async () => {
    const { controller } = await harness();
    vi.useFakeTimers();
    controller.commandsError("already_answered", { reason: "already_answered", winner: { actor_kind: "operator", summary: "Wait for QA", accepted_at: "2026-10-26T00:00:00Z" } });
    controller.setCommands({ items: [] });
    expect(controller.state().commandsView).toBe("detail");
    expect(keys(controller)[0]?.title).toBe("Wait for QA");
    vi.advanceTimersByTime(3_000);
    expect(controller.state().commandsView).toBe("history");
    expect(controller.state().commandFeedback).toBeNull();
  });

  it.each([
    [{ reason: "withdrawn", status: "expired" }, "Command withdrawn", "expired"],
    [{ reason: "stale" }, "Command changed", "Refresh and retry"],
    [{ reason: "already_answered", winner: null }, "Already answered", "Answered by someone else"],
  ] as const)("renders %j and refreshes", async (outcome, title, subLabel) => {
    const { controller, channel } = await harness();
    vi.useFakeTimers();
    controller.commandsError(outcome.reason, outcome satisfies StreamDeckCommandAnswerError);
    expect(keys(controller)[0]).toMatchObject({ title, subLabel });
    expect(channel.focus).toHaveBeenCalledWith("agent-0");
  });

  it("ignores an outcome for a different answer request", async () => {
    const { controller } = await harness();
    controller.commandsError("stale", { reason: "stale" }, "previous-request-key");
    expect(controller.state().commandFeedback).toBeNull();
    expect(controller.state().commandsError).toBeNull();
    expect(keys(controller)[0]?.title).toBe("Ship it");
  });

  it("future regression guard: keeps unknown errors readable without inventing an outcome", async () => {
    const { controller, channel } = await harness();
    controller.commandsError("store_unavailable");
    expect(controller.state().commandsError).toBe("store_unavailable");
    expect(controller.state().commandFeedback).toBeNull();
    expect(channel.focus).not.toHaveBeenCalled();
  });
});
