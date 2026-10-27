import { describe, expect, it, vi } from "vitest";
import type { StreamDeckCommand, StreamDeckGrid } from "../src/channel.js";
import { activeCommandCount, canAnswerOnDeck, detailKeyDescriptors, detailPanel, historyKeyDescriptors } from "../src/commands.js";
import { createPhysicalController } from "../src/controller.js";
import { dialButton, keyReport } from "./support/deckReports.js";

const command: StreamDeckCommand = {
  decision_id: "v2", version: 1, question: "Choose scope and timing?", short_label: "Scope",
  answerable_on_deck: false, options: [{ id: "small", label: "Small" }], status: "open",
};

describe("v2 Commands on deck", () => {
  it("renders the dashboard-only face without answer keys, keeping the pending count", () => {
    const keys = detailKeyDescriptors(command, 0, 0, true, true);
    expect(keys).toHaveLength(8);
    expect(keys[0]).toMatchObject({ title: "Answer on dashboard", subLabel: "DASHBOARD" });
    expect(keys.slice(1)).toEqual(Array(7).fill(undefined));
    expect(detailPanel(command, 0, true)).toMatchObject({ description: "Answer on dashboard", answerable: false, approving: false });
    expect(activeCommandCount({ items: [command] })).toBe(1);
    expect(historyKeyDescriptors({ items: [command] }, 0, null)[0]?.title).toBe("Scope");
  });

  it("keeps single-question and older server option faces answerable", () => {
    for (const answerable_on_deck of [true, undefined]) {
      const single = { ...command, answerable_on_deck, short_label: null };
      expect(canAnswerOnDeck(single)).toBe(true);
      expect(detailKeyDescriptors(single, 0, null, false, false)[0]?.title).toBe("Small");
      expect(detailPanel(single, 0, false).answerable).toBe(true);
      expect(historyKeyDescriptors({ items: [single] }, 0, null)[0]?.title).toBe(single.question);
    }
  });

  it("refuses option, mic and approval input for dashboard-only Commands", () => {
    const answerCommand = vi.fn();
    const grid: StreamDeckGrid = { agents: [{ identifier: "agent-0", bucket: "running" }], total: 1, windows: 1, max_column_offset: 0 };
    const channel = { answerCommand, focus: vi.fn(), commandsPage: vi.fn(), control: vi.fn(), say: vi.fn() };
    const controller = createPhysicalController({ grid: () => grid, channel: () => channel, stateChanged: vi.fn() });
    const press = (key: number) => { controller.handleReport(keyReport(key, true)); controller.handleReport(keyReport(key, false)); };
    press(0);
    press(4);
    controller.setCommands({ items: [command] });
    press(0);
    press(0);
    press(4);
    press(5);
    controller.handleReport(dialButton(3, true));
    controller.handleReport(dialButton(3, false));
    expect(controller.state().selectedOption).toBeNull();
    expect(controller.state().micHeld).toBe(false);
    expect(answerCommand).not.toHaveBeenCalled();
  });
});
