import { describe, expect, it, vi } from "vitest";
import { connectStreamDeckChannel, type StreamDeckChat, type StreamDeckChannelEvents, type WebSocketLike } from "../src/channel.js";
import { createPhysicalController } from "../src/controller.js";
import { surfaceState } from "../src/sidecar-wiring.js";
import { composeStrip } from "../src/touchStrip/stripLayout.js";
import { render, NOW } from "./art/renderSegment.js";
import { keyReport } from "./support/deckReports.js";

const chat = (over: Partial<StreamDeckChat> = {}): StreamDeckChat => ({ v: 1, kind: "chat", id: "7", state: "live", observed_at: NOW, latest: { id: "l:1", at: NOW, k: "say", text: "retained message" }, ...over });
const panel = (dto: StreamDeckChat | null) => composeStrip({ mode: "cmd", data: { chat: dto } })[0];
const paint = (dto: StreamDeckChat | null, now = NOW) => render(panel(dto).content, 800, now).ink;

describe("ticket chat strip", () => {
  it("wraps the newest entry across 800px with an inline role and no summary column", () => {
    const dto = chat({ latest: { id: "l:1", at: NOW, k: "say", text: "Wide message ".repeat(50) } });
    expect(panel(dto).region).toMatchObject({ x: 0, width: 800 });
    const ink = paint(dto);
    expect(ink.length).toBe(5);
    expect(ink[0].text).toMatch(/^● Wide message/);
    expect(ink.every((line) => line.x <= 8)).toBe(true);
    expect(ink[0].text.length).toBeGreaterThan(80);
  });
  it.each([
    ["not_retained", "Conversation not retained"], ["unavailable", "Conversation unavailable"],
    ["restart_unknown", "Conversation state unknown after restart"], ["ended", "Conversation ended"],
    ["known_empty", "No chat yet."],
  ] as const)("names %s", (state, label) => {
    expect(paint(chat({ state, latest: null })).map((line) => line.text)).toEqual([label]);
  });
  it("renders and advances stale age and keeps an absent observation unknown", () => {
    const dto = chat({ state: "stale", latest: null, observed_at: NOW - 60_000 });
    expect(paint(dto)[0].text).toBe("Conversation stale · 60s old");
    expect(paint(dto, NOW + 1_000)[0].text).toBe("Conversation stale · 61s old");
    expect(paint(chat({ state: "stale", latest: null, observed_at: null }))[0].text).toBe("Conversation stale · age unknown");
    expect(paint(chat({ state: "stale", latest: null, observed_at: NOW + 1_000 }))[0].text).toBe("Conversation stale · 0s old");
  });
  it("renders missing state, empty live state and each allowlisted role", () => {
    expect(paint(null)[0].text).toBe("Conversation unavailable");
    expect(paint(chat({ latest: null }))[0].text).toBe("No chat yet.");
    expect(paint(chat({ latest: { id: "op", at: null, k: "op", text: "go\n" } })).map((line) => line.text)).toEqual(["› go"]);
    expect(paint(chat({ latest: { id: "op", at: null, k: "op", text: "go\nnow" } })).map((line) => line.text)).toEqual(["› go", "now"]);
    expect(paint(chat({ latest: { id: "tool", at: null, k: "tool", name: "bash", arg: "mix test", res: "✗ exit 1" } }))[0].text).toBe("$ bash mix test ✗ exit 1");
    expect(paint(chat({ latest: { id: "tool", at: null, k: "tool" } }))[0].text).toBe("$ tool  ");
    expect(paint(chat({ latest: { id: "sys", at: null, k: "sys" } }))[0].text).toBe("· ");
    expect(paint(chat({ latest: { id: "op", at: null, k: "op", text: "line\n".repeat(9) } })).length).toBe(5);
  });
  it("routes channel pushes to the focused surface and types only subsequent live messages", async () => {
    const grid = { agents: [{ identifier: "7", bucket: "running" }, { identifier: "8", bucket: "running" }], total: 2, windows: 1, max_column_offset: 0 };
    const controller = createPhysicalController({ grid: () => grid, channel: () => ({ focus: vi.fn() }) as never, stateChanged: vi.fn() });
    const press = (key: number) => { controller.handleReport(keyReport(key, true)); controller.handleReport(keyReport(key, false)); };
    const events = { chat: controller.setChat } as unknown as StreamDeckChannelEvents;
    const socket: WebSocketLike = { binaryType: "", onopen: null, onmessage: null, onerror: null, onclose: null, send: vi.fn(), close: vi.fn() };
    const channel = await connectStreamDeckChannel({ baseUrl: "http://aiur.test", fetch: async () => ({ ok: true, json: async () => ({ token: "signed" }) }), websocket: () => socket, events });
    const push = (dto: StreamDeckChat) => socket.onmessage?.({ data: JSON.stringify([null, null, "streamdeck:fleet", "chat", dto]) });
    press(0);
    push(chat());
    expect(controller.state().chat?.latest?.text).toBe("retained message");
    expect(controller.tickTyping()).toBe(false);
    push(chat({ latest: { id: "l:2", at: NOW, k: "say", text: "new live message" } }));
    expect(controller.state().chat?.latest?.text).toBe("");
    controller.tickTyping();
    expect(controller.state().chat?.latest?.text).toBe("new li");
    for (let i = 0; i < 4; i++) controller.tickTyping();
    expect(controller.state().chat?.latest?.text).toBe("new live message");
    expect(surfaceState(controller.state(), [], undefined).chat?.latest?.text).toBe("new live message");
    push(chat({ id: "8" }));
    expect(controller.state().chat?.id).toBe("7");
    controller.resetInstance();
    press(4);
    expect(controller.state().chat == null).toBe(true);
    push(chat());
    expect(controller.state().chat == null).toBe(true);
    push(chat({ id: "8", state: "ended" }));
    expect(controller.state().chat?.latest?.text).toBe("retained message");
    channel.close();
  });
});
