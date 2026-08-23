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
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), commands: vi.fn(), commandAnswered: vi.fn(), commandsError: vi.fn(),
      voiceStarted: vi.fn(), voice: vi.fn(), voiceError: vi.fn(), voiceClosed: vi.fn(), voiceAvailability: vi.fn(), closed: vi.fn(),
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
    // The live per-message push enters the transcript as a message row, so the
    // strip can attribute it to a speaker.
    socket.message(["4", "4", "streamdeck:fleet", "transcript", { identifier: "1358", role: "tool", body: "ran the tests" }]);
    socket.message(["4", "5", "streamdeck:fleet", "transcript", { identifier: "1358", body: 42 }]);
    channel.control("1358", "pause");
    expect(JSON.parse(socket.sent[1])).toEqual(["4", "2", "streamdeck:fleet", "control", { identifier: "1358", action: "pause" }]);
    // Transcribed speech goes out as its own event carrying operator text,
    // not as a `control` verb; the server length-caps it and hands it to the
    // same AgentChat path as the dashboard chat box.
    channel.say("1358", "run the tests again");
    expect(JSON.parse(socket.sent[2])).toEqual(["4", "3", "streamdeck:fleet", "say", { identifier: "1358", text: "run the tests again" }]);
    expect(events.snapshot).toHaveBeenCalledOnce();
    expect(events.grid).toHaveBeenCalledOnce();
    expect(events.logs).toHaveBeenCalledWith({ event_keys: [{ label: "LIVE" }], transcript: [{ body: "chat" }] });
    expect(events.transcript).toHaveBeenNthCalledWith(1, { kind: "message", role: "tool", body: "ran the tests", tool: null });
    expect(events.transcript).toHaveBeenNthCalledWith(2, { kind: "message", role: "agent", body: "", tool: null });
  });

  it("queues focus until join and reports Phoenix channel shutdown frames", async () => {
    const socket = socketHarness();
    const events = {
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), commands: vi.fn(), commandAnswered: vi.fn(), commandsError: vi.fn(),
      voiceStarted: vi.fn(), voice: vi.fn(), voiceError: vi.fn(), voiceClosed: vi.fn(), voiceAvailability: vi.fn(), closed: vi.fn(),
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
    const queuedFocus = JSON.parse(socket.sent[1]);
    expect(queuedFocus).toEqual(["4", "2", "streamdeck:fleet", "focus", { identifier: "1358" }]);
    expect(Number(queuedFocus[1])).toBeGreaterThan(Number(JSON.parse(socket.sent[0])[1]));
    socket.message(["", "", "", "phx_close", {}]);
    expect(events.closed).toHaveBeenCalledWith(expect.any(Error));
    channel.close();
  });

  describe("voice", () => {
    const voiceEvents = () => ({
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), commands: vi.fn(), commandAnswered: vi.fn(), commandsError: vi.fn(),
      voiceStarted: vi.fn(), voice: vi.fn(), voiceError: vi.fn(), voiceClosed: vi.fn(), voiceAvailability: vi.fn(), closed: vi.fn(),
    });

    const joined = async (events: ReturnType<typeof voiceEvents>) => {
      const socket = socketHarness();
      const channel = await connectStreamDeckChannel({
        baseUrl: "http://aiur.test:4000",
        username: "operator",
        password: "secret",
        fetch: vi.fn(async () => ({ ok: true, json: async () => ({ token: "signed-token" }) })),
        websocket: vi.fn(() => socket),
        events,
      });
      socket.open();
      socket.message(["4", "1", "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
      return { socket, channel };
    };

    const sentRef = (socket: { sent: string[] }, index: number): string => JSON.parse(socket.sent[index])[1] as string;

    it("sends the three voice events with the payloads the server expects", async () => {
      const { socket, channel } = await joined(voiceEvents());
      channel.voiceStart();
      channel.voiceAudio("s-1", "QUJD");
      channel.voiceStop("s-1");
      expect(socket.sent.slice(1).map((frame) => JSON.parse(frame).slice(2))).toEqual([
        ["streamdeck:fleet", "voice_start", {}],
        ["streamdeck:fleet", "voice_audio", { session: "s-1", audio: "QUJD" }],
        ["streamdeck:fleet", "voice_stop", { session: "s-1" }],
      ]);
    });

    /**
     * `voice_start`'s session id comes back in a `phx_reply`, so the client has
     * to correlate a reply with the request that produced it. Before this,
     * `onmessage` read `phx_reply` only to detect the join.
     */
    it("correlates the voice_start reply to its own request", async () => {
      const events = voiceEvents();
      const { socket, channel } = await joined(events);
      channel.focus("1358");
      channel.voiceStart();
      const startRef = sentRef(socket, 2);
      // A reply to the *focus* is not the voice reply, even though it arrives first.
      socket.message(["4", sentRef(socket, 1), "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
      expect(events.voiceStarted).not.toHaveBeenCalled();
      socket.message(["4", startRef, "streamdeck:fleet", "phx_reply", { status: "ok", response: { session: "s-9" } }]);
      expect(events.voiceStarted).toHaveBeenCalledExactlyOnceWith("s-9", null);
    });

    it("reports a refusal, with and without a reason", async () => {
      const refused = voiceEvents();
      const first = await joined(refused);
      first.channel.voiceStart();
      first.socket.message(["4", sentRef(first.socket, 1), "streamdeck:fleet", "phx_reply", { status: "error", response: { reason: "unconfigured" } }]);
      expect(refused.voiceStarted).toHaveBeenCalledWith(null, "unconfigured");

      const silent = voiceEvents();
      const second = await joined(silent);
      second.channel.voiceStart();
      second.socket.message(["4", sentRef(second.socket, 1), "streamdeck:fleet", "phx_reply", { status: "error" }]);
      expect(silent.voiceStarted).toHaveBeenCalledWith(null, null);
    });

    // An `ok` with no session is a server that agreed to something it did not
    // then identify; treating it as success would leave every frame unaddressed.
    it("treats an ok reply with no session as a refusal", async () => {
      const events = voiceEvents();
      const { socket, channel } = await joined(events);
      channel.voiceStart();
      socket.message(["4", sentRef(socket, 1), "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
      expect(events.voiceStarted).toHaveBeenCalledWith(null, null);
    });

    // The join is addressed by its own ref now, and a voice reply must not be
    // mistaken for it — that would re-flush the queued-command list.
    it("keeps the join behaviour intact while voice replies are in flight", async () => {
      const events = voiceEvents();
      const socket = socketHarness();
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
      expect(JSON.parse(socket.sent[1])[3]).toBe("focus");
      channel.voiceStart();
      socket.message(["4", sentRef(socket, 2), "streamdeck:fleet", "phx_reply", { status: "ok", response: { session: "s-1" } }]);
      // Exactly one focus went out: the voice reply did not re-flush the queue.
      expect(socket.sent.filter((frame) => JSON.parse(frame)[3] === "focus")).toHaveLength(1);
    });

    it("routes the three inbound voice pushes", async () => {
      const events = voiceEvents();
      const { socket } = await joined(events);
      socket.message(["4", "9", "streamdeck:fleet", "voice", { session: "s-1", kind: "final", text: "run the tests" }]);
      socket.message(["4", "9", "streamdeck:fleet", "voice_error", { session: "s-1", reason: "provider hung up" }]);
      socket.message(["4", "9", "streamdeck:fleet", "voice_closed", { session: "s-1" }]);
      expect(events.voice).toHaveBeenCalledWith("s-1", "final", "run the tests");
      expect(events.voiceError).toHaveBeenCalledWith("s-1", "provider hung up");
      expect(events.voiceClosed).toHaveBeenCalledWith("s-1");
    });

    it("corrects unambiguous Aiur dictation before the operator or agent sees it", async () => {
      const events = voiceEvents();
      const { socket } = await joined(events);
      socket.message(["4", "9", "streamdeck:fleet", "voice", { session: "s-1", kind: "final", text: "A, your fleet follows AEOR" }]);
      expect(events.voice).toHaveBeenCalledWith("s-1", "final", "Aiur fleet follows Aiur");
    });

    // `final_transcript` is still revisable upstream, so anything not explicitly
    // final is a partial — the direction that keeps text out of the settled buffer.
    it("normalises a malformed voice push instead of dropping it", async () => {
      const events = voiceEvents();
      const { socket } = await joined(events);
      socket.message(["4", "9", "streamdeck:fleet", "voice", {}]);
      socket.message(["4", "9", "streamdeck:fleet", "voice_error", {}]);
      socket.message(["4", "9", "streamdeck:fleet", "voice_closed", {}]);
      expect(events.voice).toHaveBeenCalledWith("", "partial", "");
      expect(events.voiceError).toHaveBeenCalledWith("", "Transcription failed");
      expect(events.voiceClosed).toHaveBeenCalledWith("");
    });

    it("reads voice availability off the snapshot", async () => {
      const events = voiceEvents();
      const { socket } = await joined(events);
      const snapshot = (voice?: unknown) => ({ version: 1, fleet: { agents: [] }, usage: {}, decisions: {}, ...(voice === undefined ? {} : { voice }) });
      socket.message(["4", "9", "streamdeck:fleet", "snapshot", snapshot({ available: true, reason: null })]);
      expect(events.voiceAvailability).toHaveBeenLastCalledWith({ available: true, reason: null });
      socket.message(["4", "9", "streamdeck:fleet", "snapshot", snapshot({ available: false, reason: "no key" })]);
      expect(events.voiceAvailability).toHaveBeenLastCalledWith({ available: false, reason: "no key" });
      // A daemon older than this sidecar sends no entry at all; promising a
      // transcription nobody can perform is the one wrong answer here.
      socket.message(["4", "9", "streamdeck:fleet", "snapshot", snapshot()]);
      expect(events.voiceAvailability).toHaveBeenLastCalledWith({ available: false, reason: null });
    });
  });

  describe("commands", () => {
    const commandsEvents = () => ({
      snapshot: vi.fn(), fleet: vi.fn(), grid: vi.fn(), usage: vi.fn(), transcript: vi.fn(), logs: vi.fn(), control: vi.fn(), commands: vi.fn(), commandAnswered: vi.fn(), commandsError: vi.fn(),
      voiceStarted: vi.fn(), voice: vi.fn(), voiceError: vi.fn(), voiceClosed: vi.fn(), voiceAvailability: vi.fn(), closed: vi.fn(),
    });

    const joined = async (events: ReturnType<typeof commandsEvents>) => {
      const socket = socketHarness();
      const channel = await connectStreamDeckChannel({
        baseUrl: "http://aiur.test:4000",
        username: "operator",
        password: "secret",
        fetch: vi.fn(async () => ({ ok: true, json: async () => ({ token: "signed-token" }) })),
        websocket: vi.fn(() => socket),
        events,
      });
      socket.open();
      socket.message(["4", "1", "streamdeck:fleet", "phx_reply", { status: "ok", response: {} }]);
      return { socket, channel };
    };

    // The exact version the device read and the idempotency key must survive
    // the trip to the wire, or the server could not tell a stale press from a
    // replay — the whole "conflict, never a double-answer" contract.
    it("sends answer_command with the exact decision, version, idempotency key and answer", async () => {
      const { socket, channel } = await joined(commandsEvents());
      channel.answerCommand("dec-9", 7, "sd-key-1", { option_id: "ship" });
      channel.answerCommand("dec-9", 7, "sd-key-2", { custom_response: "Hold everything" });
      const frames = socket.sent.slice(1).map((frame) => JSON.parse(frame).slice(2));
      expect(frames).toEqual([
        ["streamdeck:fleet", "answer_command", { decision_id: "dec-9", version: 7, idempotency_key: "sd-key-1", option_id: "ship" }],
        ["streamdeck:fleet", "answer_command", { decision_id: "dec-9", version: 7, idempotency_key: "sd-key-2", custom_response: "Hold everything" }],
      ]);
    });

    it("routes the answer_command reply to commandAnswered or commandsError", async () => {
      const events = commandsEvents();
      const { socket, channel } = await joined(events);
      channel.answerCommand("dec-9", 7, "sd-key-1", { option_id: "ship" });
      socket.message(["4", JSON.parse(socket.sent[1])[1], "streamdeck:fleet", "phx_reply", { status: "ok", response: { status: "accepted", decision: { decision_id: "dec-9", version: 7, status: "decided" } } }]);
      expect(events.commandAnswered).toHaveBeenCalledWith({ status: "accepted", decision: { decision_id: "dec-9", version: 7, status: "decided" } });

      channel.answerCommand("dec-9", 7, "sd-key-2", { option_id: "ship" });
      socket.message(["4", JSON.parse(socket.sent[2])[1], "streamdeck:fleet", "phx_reply", { status: "error", response: { reason: "conflict: stale_version" } }]);
      expect(events.commandsError).toHaveBeenCalledWith("conflict: stale_version");
    });
  });
});
