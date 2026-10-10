import { describe, expect, it, vi } from "vitest";
import { createPhysicalController } from "../src/controller.js";
import type { StreamDeckGrid } from "../src/channel.js";
import { dialButton, dialTurn, keyReport } from "./support/deckReports.js";
import { PROVIDER_SCROLL_ENCODER } from "../src/touchStrip/providerPanel.js";

const grid = (count = 10): StreamDeckGrid => ({
  agents: Array.from({ length: count }, (_, index) => ({
    identifier: `agent-${index}`,
    bucket: index === 6 ? "running" : "queued",
    title: `Agent ${index}`,
    vendor: "codex",
    progress_percent: 20,
  })),
  total: count,
  windows: Math.ceil(count / 8),
  max_column_offset: Math.max(0, Math.ceil(count / 2) - 4),
});

describe("physical controller composition", () => {
  // Routing a detent through the mock's 0-100 knob value made one click worth a
  // fraction of a column, so the operator had to click two or three times for
  // every step. A detent is one position.
  it("moves the grid exactly one column per dial detent", () => {
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(1);
    controller.handleReport(dialTurn(3, 1));
    expect(controller.state().columnOffset).toBe(2);
    controller.handleReport(dialTurn(3, -1));
    expect(controller.state().columnOffset).toBe(1);
  });

  it("applies a multi-detent report in one step", () => {
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 3));
    expect(controller.state().columnOffset).toBe(3);
  });

  it("clamps at both ends of the column range", () => {
    // 20 agents -> ceil(20/2) - 4 = 6 columns of travel.
    const controller = createPhysicalController({ grid: () => grid(20), channel: () => null, stateChanged: vi.fn() });
    controller.handleReport(dialTurn(3, 99));
    expect(controller.state().columnOffset).toBe(6);
    controller.handleReport(dialTurn(3, -99));
    expect(controller.state().columnOffset).toBe(0);
  });

  describe("provider scroll on knob 2", () => {
    const scrolling = (providerCount: number, stateChanged = vi.fn()) =>
      createPhysicalController({ grid, channel: () => null, providerCount: () => providerCount, stateChanged });

    // Same detent lesson as the grid columns: the offset steps from the report's
    // own ticks, so one click is one provider rather than a fraction of one.
    it("moves the list exactly one provider per detent", () => {
      const controller = scrolling(6);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(controller.state().providerOffset).toBe(1);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(controller.state().providerOffset).toBe(2);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -1));
      expect(controller.state().providerOffset).toBe(1);
    });

    it("applies a multi-detent report in one step", () => {
      const controller = scrolling(9);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 3));
      expect(controller.state().providerOffset).toBe(3);
    });

    // Unclamped, a long spin would have to be unwound click for click before the
    // list moved again.
    it("clamps at both ends of the provider list", () => {
      const controller = scrolling(5);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 99));
      expect(controller.state().providerOffset).toBe(2);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -99));
      expect(controller.state().providerOffset).toBe(0);
    });

    it("does not move when every provider already fits", () => {
      const controller = scrolling(3);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    // The provider panel belongs to the grid strip. Scrolling it from cmd or
    // logs would move something the operator cannot see.
    it("is inert outside the grid", () => {
      const controller = scrolling(6);
      controller.handleReport(keyReport(0, true));
      controller.handleReport(keyReport(0, false));
      expect(controller.state().mode).toBe("cmd");
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    it("cannot scroll on a host with no usage feed", () => {
      const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state().providerOffset).toBe(0);
    });

    // The strip only repaints on a state change, so a scroll that does not
    // publish is a scroll the operator never sees.
    it("publishes the new offset so the strip repaints", () => {
      const changed = vi.fn();
      const controller = scrolling(6, changed);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 1));
      expect(changed).toHaveBeenCalledWith(expect.objectContaining({ providerOffset: 1 }));
    });

    // The panel clamps again when it paints, so a stale stored offset does not
    // show a wrong window — it eats the next detent, and the knob looks dead at
    // exactly the moment the fleet changed under the operator. The demo chord
    // on this same knob swaps the provider set, so this is a normal path.
    it("keeps moving on the first detent after the provider list shrinks", () => {
      let providers = 9;
      const controller = createPhysicalController({
        grid,
        channel: () => null,
        providerCount: () => providers,
        stateChanged: vi.fn(),
      });
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 6));
      expect(controller.state().providerOffset).toBe(6);

      providers = 5;
      // The painted window is now clamped to 2; one detent up must land on 1,
      // not back on the row already showing.
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, -1));
      expect(controller.state().providerOffset).toBe(1);
    });

    it("leaves the other knobs' offsets alone", () => {
      const controller = scrolling(6);
      controller.handleReport(dialTurn(PROVIDER_SCROLL_ENCODER, 2));
      expect(controller.state()).toMatchObject({ columnOffset: 0, eventOffset: 0, chatOffset: 0 });
    });
  });

  /**
   * The key window opens at the newest end and dial D scrolls back from there.
   *
   * It no longer adopts the server's `events_offset`. Where the operator is
   * reading is a client-side position — the daemon flushes several times a
   * second and has no idea the deck is even on this surface — and the one
   * position that is always right on arrival is "the end", because that is
   * where the agent is.
   */
  it("opens the key window at the newest end and pages back from there", () => {
    const controller = createPhysicalController({ grid, channel: () => null, stateChanged: vi.fn() });
    controller.setLogs({
      event_keys: Array.from({ length: 20 }, (_, index) => ({
        kind: index === 19 ? "live" : "event",
        text: `event-${index}`,
        start: index,
      })),
      events_offset: 8,
      events_max_offset: 12,
      transcript: Array.from({ length: 20 }, (_, index) => ({ kind: "event_header", body: `chat-${index}` })),
    });
    expect(controller.state().eventOffset).toBe(12);
    controller.handleReport(keyReport(0, true));
    controller.handleReport(keyReport(0, false));
    controller.handleReport(dialButton(3));
    controller.handleReport(dialButton(3, false));
    controller.handleReport(dialTurn(3, -1));
    expect(controller.state().eventOffset).toBe(11);
  });
});
