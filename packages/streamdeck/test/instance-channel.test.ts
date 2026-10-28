import { expect, it, vi } from "vitest";
import { connectStreamDeckChannel } from "../src/channel.js";
import { InstanceAuthError, type StreamDeckChannelEvents, type WebSocketLike } from "../src/channel-types.js";
import { guardChannelEvents } from "../src/instance-events.js";

const events = (): StreamDeckChannelEvents => ({ snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), commands: vi.fn(), commandAnswered: vi.fn(), commandsError: vi.fn(), voiceStarted: vi.fn(), voice: vi.fn(), voiceError: vi.fn(), voiceClosed: vi.fn(), voiceAvailability: vi.fn(), closed: vi.fn() });
it.each([401, 403, 500])("classifies token response %i without disclosing credentials", async (status) => {
  const websocket = vi.fn();
  const promise = connectStreamDeckChannel({ baseUrl: "https://remote.test", token: "never-print-me", fetch: async () => ({ ok: false, status, json: async () => ({}) }), websocket, events: events() });
  await expect(promise).rejects.toThrow(status === 500 ? "token request failed" : InstanceAuthError);
  expect(websocket).not.toHaveBeenCalled();
});
it("delivers current frames and discards old socket callbacks", async () => {
  const handlers = events(); let current = true;
  const socket: WebSocketLike = { binaryType: "", onopen: null, onclose: null, onerror: null, onmessage: null, send: vi.fn(), close: vi.fn() };
  const fetch = vi.fn(async () => ({ ok: true, json: async () => ({ token: "signed-token" }) }));
  const channel = await connectStreamDeckChannel({ baseUrl: "https://remote.test", token: "per-instance-bearer", fetch, websocket: () => socket, events: guardChannelEvents(handlers, () => current) });
  expect(fetch.mock.calls[0]).toEqual(["https://remote.test/api/v1/streamdeck/token", expect.objectContaining({ headers: expect.objectContaining({ Authorization: "Bearer per-instance-bearer" }) })]);
  socket.onmessage?.({ data: JSON.stringify([null, null, "streamdeck:fleet", "fleet", { grid: { agents: [], total: 2, windows: 1, max_column_offset: 0 } }]) });
  expect(handlers.grid).toHaveBeenCalledOnce(); current = false;
  socket.onmessage?.({ data: JSON.stringify([null, null, "streamdeck:fleet", "fleet", { grid: { agents: [], total: 99 } }]) });
  socket.onerror?.(new Error("old connection"));
  expect(handlers.grid).toHaveBeenCalledOnce(); expect(handlers.closed).not.toHaveBeenCalled(); channel.close();
});
