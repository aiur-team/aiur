import { describe, it, expect, vi } from "vitest";
import { createPhysicalController, type ControllerVoice } from "../src/controller.js";
import { descriptorCommands } from "../src/surface.js";
import { openTicketLink } from "../src/controller/ticket-actions.js";
import type { StreamDeckTicket } from "../src/channel.js";
import { keyReport } from "./support/deckReports.js";

const dto: StreamDeckTicket = {
  v: 1, kind: "ticket", id: "77", title: "Ticket", sec: "now",
  status: { label: "Running", tone: "active", agent_state: "working" },
  agent: null, pr: { num: 88, state: "open" }, qpos: 3, observed_at: 1,
  control: { action: "pause", state: "enabled", title: "Pause" },
  actions: { pause: "enabled", priority_up: "enabled", priority_down: "enabled" },
  links: { pr: "https://github.com/acme/aiur/pull/88", modal: "http://localhost:4000/build?ticket=77" },
};
const setup = (voice?: ControllerVoice) => {
  const channel = { focus: vi.fn(), control: vi.fn(), say: vi.fn(), commandsPage: vi.fn(), answerCommand: vi.fn(), priority: vi.fn() };
  const child = { stdout: null, on: vi.fn(), kill: vi.fn() };
  const spawn = vi.fn(() => child);
  const grid = { agents: [{ identifier: "77", bucket: "running" }], total: 1, windows: 1, max_column_offset: 0 };
  const controller = createPhysicalController({ grid: () => grid, channel: () => channel, voice: () => voice ?? null, spawn, stateChanged: vi.fn() });
  const press = (index: number) => { controller.handleReport(keyReport(index, true)); controller.handleReport(keyReport(index, false)); };
  press(0);
  controller.setTicket(dto);
  return { controller, channel, spawn, press, grid, child };
};

describe("ticket page actions", () => {
  it("opens only server PR/dashboard links through the injected spawn", () => {
    const { controller, press, spawn, grid } = setup();
    grid.agents = []; // Focus survives the fleet row leaving.
    press(4); press(5);
    expect(spawn.mock.calls).toEqual([["xdg-open", [dto.links!.pr]], ["xdg-open", [dto.links!.modal]]]);
    spawn.mockClear();
    controller.setTicket({ ...dto, links: { pr: null, modal: "file:///etc/passwd" } });
    press(4); press(5);
    expect(spawn).not.toHaveBeenCalled();
  });

  it("routes priority, pause/resume and Commands from the focused DTO and respects disabled keys", () => {
    const { controller, press, channel } = setup();
    press(1); press(2); press(0);
    expect(channel.priority.mock.calls).toEqual([["77", "up"], ["77", "down"]]);
    expect(channel.control).toHaveBeenLastCalledWith("77", "pause");
    controller.setTicket({ ...dto, control: { ...dto.control!, action: "resume" } });
    press(0);
    expect(channel.control).toHaveBeenLastCalledWith("77", "resume");
    controller.setTicket({ ...dto, actions: { pause: "disabled", priority_up: "disabled", priority_down: "disabled" }, links: { pr: null, modal: dto.links!.modal } });
    channel.control.mockClear(); channel.priority.mockClear();
    press(0); press(1); press(2);
    expect(channel.control).not.toHaveBeenCalled(); expect(channel.priority).not.toHaveBeenCalled();
    const faces = descriptorCommands(null, false, false, 0, false, controller.state().ticket);
    expect([faces[0], faces[1], faces[2], faces[4]].map((face) => face?.subLabel)).toEqual(["DISABLED", "DISABLED", "DISABLED", "DISABLED"]);
    press(3);
    expect(controller.state().mode).toBe("commands");
  });

  it("preserves Implement for a ticket with no agent", () => {
    const { controller, press, channel, grid } = setup();
    grid.agents[0]!.bucket = "queued";
    controller.setTicket({ ...dto, control: null, actions: { ...dto.actions!, pause: "disabled" } });
    expect(descriptorCommands(grid.agents[0], false, false, 0, false, controller.state().ticket)[0]?.title).toBe("Implement");
    press(0);
    expect(channel.control).toHaveBeenCalledWith("77", "implement");
    expect(controller.state().implementQueued).toBe(true);
  });

  it("routes the relocated microphone and dictation keys through HID input", () => {
    let text = "";
    const voice: ControllerVoice = {
      hold: vi.fn(), release: vi.fn(), message: () => text, hasMessage: () => text !== "",
      clear: vi.fn(() => { text = ""; }), dispose: vi.fn(), microphones: () => [],
      refresh: vi.fn(), selectedDeviceId: () => null, select: vi.fn(),
    };
    const { controller, press, channel, spawn } = setup(voice);
    press(6);
    expect(voice.hold).toHaveBeenCalledOnce(); expect(voice.release).toHaveBeenCalledOnce();
    text = "continue the ticket";
    controller.refreshVoice(); press(4);
    expect(channel.say).toHaveBeenCalledWith("77", "continue the ticket");
    expect(spawn).not.toHaveBeenCalled();
    text = "discard this";
    controller.refreshVoice(); press(5);
    expect(text).toBe(""); expect(channel.say).toHaveBeenCalledTimes(1);
  });

  it("reports opener failures and paints dictation keys", () => {
    const { controller, child, press, spawn } = setup();
    press(4);
    const error = vi.fn();
    child.on.mockClear();
    openTicketLink(dto.links!.pr, spawn, error);
    const listeners = child.on.mock.calls as unknown as [string, (reason: unknown) => void][];
    listeners.find(([event]) => event === "error")![1]("missing xdg-open");
    expect(error).toHaveBeenCalledWith("missing xdg-open");
    const faces = descriptorCommands(null, false, true, 0, false, dto);
    expect(faces[4]?.title).toBe("Send"); expect(faces[5]?.title).toBe("Cancel");
    expect(controller.state().mode).toBe("cmd");
  });
});
