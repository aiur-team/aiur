import { createCanvas } from "@napi-rs/canvas";
import { describe, expect, it, vi } from "vitest";
import { connectStreamDeckChannel, type StreamDeckGrid, type StreamDeckTicket, type StreamDeckChannelEvents, type WebSocketLike } from "../src/channel.js";
import { createPhysicalController } from "../src/controller.js";
import { createPhysicalSurface, descriptorCommands } from "../src/surface.js";
import { surfaceState } from "../src/sidecar-wiring.js";
import { ticketDetailModel } from "../src/touchStrip/ticketDetail.js";
import { render, NOW } from "./art/renderSegment.js";
import { dialButton, keyReport } from "./support/deckReports.js";

const ticket = (over: Partial<StreamDeckTicket> = {}): StreamDeckTicket => ({
  v: 1, kind: "ticket", id: "401", title: "Ticket from Build", sec: "now",
  status: { label: "Waiting for CI", tone: "idle", agent_state: "ci_wait" },
  agent: { model: "codex", name: "Codex", effort: "high", pct: 72, start: NOW - 120_000 },
  pr: { num: 77, state: "open", ci: "pr_opened" }, control: null, qpos: null, observed_at: NOW,
  ...over,
});
const text = (dto: StreamDeckTicket | null, now = NOW) => render({ kind: "agentDetail", model: ticketDetailModel(dto, "401", now) }, 800, now).ink.map((entry) => entry.text);

describe("Build ticket page", () => {
  it.each([
    ["ci_wait", "Waiting for CI"], ["ci-red", "CI red"], ["merge-queued", "Merge queued"],
    ["usage_limited", "Usage limited"], ["parked", "Parked"],
  ])("renders the server Build label for %s without grid taxonomy", (state, label) => {
    const dto = ticket({ status: { label, tone: "idle", agent_state: state } });
    expect(ticketDetailModel(dto, dto.id, NOW)).toMatchObject({ status: label, percent: 72, elapsedLabel: "2m", vendor: "codex" });
    expect(text(dto)).toContain(label.toUpperCase());
    expect(text(dto)).toContain("#77 · pr_opened");
  });

  it("renders an actual stale age and advances it from the observation time", () => {
    const dto = ticket();
    expect(text(dto)).not.toContain("1M OLD");
    expect(text(dto, NOW + 60_000)).toContain("1M OLD");
    expect(text(dto, NOW + 180_000)).toContain("3M OLD");
  });

  it("keeps missing PR, progress, runtime and observation evidence unknown", () => {
    const dto = ticket({ pr: null, agent: null, observed_at: null });
    expect(ticketDetailModel(dto, dto.id, NOW)).toMatchObject({ prLabel: null, percent: null, elapsedLabel: null, observedAt: null });
    const painted = text(dto);
    expect(painted).toContain("—");
    expect(painted.some((line) => /#|NO PR|GREEN|OLD|ELAPSED/.test(line))).toBe(false);
    expect(ticketDetailModel(null, null, NOW)).toMatchObject({ ticketId: "—", title: "Untitled ticket", status: "State unknown", percent: null });
    expect(text(null)).toContain("STATE UNKNOWN");
  });

  it("shows an evidenced PR without inventing its absent CI stage", () => {
    expect(text(ticket({ pr: { num: 77, state: "open" }, agent: { model: null, name: null, effort: null, pct: 0, start: null } }))).toContain("#77");
    expect(ticketDetailModel(ticket({ title: null }), null).title).toBe("Untitled ticket");
    expect(ticketDetailModel(ticket({ agent: { model: null, name: null, effort: null, pct: 20, start: NOW + 500 } }), "401", NOW).elapsedLabel).toBe("0s");
  });

  it("uses the ticket for status and PR keys while dictation keeps Send/Cancel", () => {
    const dto = ticket();
    const keys = descriptorCommands({ identifier: "401", bucket: "running" }, false, false, 0, false, dto);
    expect(keys[5]).toMatchObject({ title: "Waiting for CI", subLabel: "STATUS" });
    expect(keys[6]).toMatchObject({ title: "#77", subLabel: "pr_opened" });
    expect(descriptorCommands(null, false, false, 0, false, ticket({ pr: null }))[6]).toBeUndefined();
    expect(descriptorCommands(null, false, false, 0, false, ticket({ pr: { num: 77, state: "open" } }))[6]).toMatchObject({ subLabel: "open" });
    const dictating = descriptorCommands(null, false, true, 0, false, dto);
    expect(dictating[5]).toMatchObject({ title: "Send" });
    expect(dictating[6]).toMatchObject({ title: "Cancel" });
  });

  it("keeps Build status keys while the cmd strip names unavailable chat", async () => {
    const context = createCanvas(800, 100).getContext("2d");
    const fillText = vi.spyOn(Object.getPrototypeOf(context), "fillText");
    const surface = createPhysicalSurface();
    const backend = { write: vi.fn(async () => undefined), sendFeatureReport: vi.fn(async () => undefined) } as never;
    const grid: StreamDeckGrid = { agents: [{ identifier: "401", bucket: "running", title: "Wrong grid title" }], total: 1, windows: 1, max_column_offset: 0 };
    try {
      await surface.repaint(backend, grid, {}, undefined, { mode: "cmd", focusedIdentifier: "401", columnOffset: 0, ticket: ticket() });
      expect(fillText.mock.calls.map(([value]) => value)).toContain("Conversation unavailable");
      expect(fillText.mock.calls.map(([value]) => value)).toContain("Waiting for CI");
      fillText.mockClear();
      await surface.repaint(backend, { ...grid, agents: [] }, {}, undefined, { mode: "cmd", focusedIdentifier: "401", columnOffset: 0, ticket: ticket({ title: "Still focused" }) });
      expect(fillText.mock.calls.map(([value]) => value)).toContain("Conversation unavailable");
      fillText.mockClear();
      await surface.repaint(backend, grid, {}, undefined, { mode: "cmd", focusedIdentifier: "402", columnOffset: 0, ticket: ticket() });
      expect(fillText.mock.calls.map(([value]) => value)).toContain("Conversation unavailable");
      expect(fillText.mock.calls.map(([value]) => value)).not.toContain("Ticket from Build");
    } finally {
      fillText.mockRestore();
    }
  });

  it("routes channel ticket pushes through focused controller state to the surface", async () => {
    const grid: StreamDeckGrid = { agents: [{ identifier: "401", bucket: "running", title: "Wrong grid title" }, { identifier: "402", bucket: "queued" }], total: 2, windows: 1, max_column_offset: 0 };
    const control = vi.fn();
    const say = vi.fn();
    const controller = createPhysicalController({ grid: () => grid, channel: () => ({ focus: vi.fn(), control, say, commandsPage: vi.fn(), answerCommand: vi.fn() }), stateChanged: vi.fn() });
    const events = Object.fromEntries(["snapshot", "fleet", "grid", "usage", "transcript", "logs", "control", "voiceStarted", "voice", "voiceError", "voiceClosed", "voiceAvailability", "commands", "commandAnswered", "commandsError", "closed"].map((name) => [name, vi.fn()])) as unknown as StreamDeckChannelEvents;
    events.ticket = controller.setTicket;
    const socket: WebSocketLike = { binaryType: "", onopen: null, onmessage: null, onerror: null, onclose: null, send: vi.fn(), close: vi.fn() };
    const channel = await connectStreamDeckChannel({ baseUrl: "http://aiur.test", fetch: async () => ({ ok: true, json: async () => ({ token: "signed" }) }), websocket: () => socket, events });
    const push = (dto: StreamDeckTicket) => socket.onmessage?.({ data: JSON.stringify([null, null, "streamdeck:fleet", "ticket", dto]) });
    const press = (key: number) => { controller.handleReport(keyReport(key, true)); controller.handleReport(keyReport(key, false)); };
    press(0);
    push(ticket());
    expect(controller.state().ticket).toEqual(ticket());
    expect(surfaceState(controller.state(), [], undefined).ticket?.title).toBe("Ticket from Build");
    press(5); press(6);
    expect(say).not.toHaveBeenCalled();
    expect(control).not.toHaveBeenCalled();
    controller.handleReport(dialButton(0)); controller.handleReport(dialButton(0, false));
    press(4);
    expect(controller.state().focusedIdentifier).toBe("402");
    expect(controller.state().ticket).toBeNull();
    push(ticket());
    expect(controller.state().ticket).toBeNull();
    push(ticket({ id: "402", title: null, agent: null, pr: null }));
    expect(controller.state().ticket?.id).toBe("402");
    channel.close();
  });
});
