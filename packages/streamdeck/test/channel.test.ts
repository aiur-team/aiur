import { describe, expect, it, vi } from "vitest";
import { connectStreamDeckChannel, type WebSocketLike } from "../src/channel.js";

const socketHarness = (): WebSocketLike & { sent: string[]; open(): void; message(value: unknown): void } => {
  const socket: WebSocketLike & { sent: string[] } = {
    binaryType: "",
    onopen: null,
    onmessage: null,
    onerror: null,
    onclose: null,
    sent: [] as string[],
    send(data: string) { this.sent.push(data); },
    close: vi.fn(),
  };
  return Object.assign(socket, {
    open: () => socket.onopen?.(),
    message: (value: unknown) => socket.onmessage?.({ data: JSON.stringify(value) }),
  });
};

describe("Stream Deck Phoenix channel", () => {
  it("mints a token, joins, consumes projected state, and sends control", async () => {
    const socket = socketHarness();
    const events = {
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), closed: vi.fn(),
    };
    const channel = await connectStreamDeckChannel({
      baseUrl: "http://aiur.test:4000",
      username: "operator",
      password: "secret",
      fetch: vi.fn(async () => ({ ok: true, json: async () => ({ token: "signed-token" }) })),
      websocket: vi.fn(() => socket),
      events,
    });

    socket.open();
    expect(JSON.parse(socket.sent[0])).toEqual(["4", "1", "streamdeck:fleet", "phx_join", {}]);
    socket.message(["4", "1", "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
    socket.message(["4", "2", "streamdeck:fleet", "snapshot", { version: 1, fleet: { agents: [] }, usage: {}, decisions: {}, grid: { agents: [], total: 0, windows: 0, max_column_offset: 0 } }]);
    socket.message(["4", "3", "streamdeck:fleet", "logs", { event_keys: [{ label: "LIVE" }], transcript: [{ body: "chat" }] }]);
    channel.control("1358", "pause");
    expect(JSON.parse(socket.sent[1])).toEqual(["4", "2", "streamdeck:fleet", "control", { identifier: "1358", action: "pause" }]);
    expect(events.snapshot).toHaveBeenCalledOnce();
    expect(events.grid).toHaveBeenCalledOnce();
    expect(events.logs).toHaveBeenCalledWith({ event_keys: [{ label: "LIVE" }], transcript: [{ body: "chat" }] });
  });

  it("queues focus until join and reports Phoenix channel shutdown frames", async () => {
    const socket = socketHarness();
    const events = {
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), closed: vi.fn(),
    };
    const channel = await connectStreamDeckChannel({
      baseUrl: "http://aiur.test:4000",
      username: "operator",
      password: "secret",
      fetch: vi.fn(async () => ({ ok: true, json: async () => ({ token: "signed-token" }) })),
      websocket: vi.fn(() => socket),
      events,
    });

    channel.focus("1358");
    socket.open();
    expect(socket.sent).toHaveLength(1);
    socket.message(["4", "1", "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
    expect(JSON.parse(socket.sent[1])).toEqual(["4", "1", "streamdeck:fleet", "focus", { identifier: "1358" }]);
    socket.message(["", "", "", "phx_close", {}]);
    expect(events.closed).toHaveBeenCalledWith(expect.any(Error));
    channel.close();
  });
});
