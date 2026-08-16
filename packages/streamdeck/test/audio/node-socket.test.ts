import { beforeEach, describe, expect, it, vi } from "vitest";
import { createNodeSocket } from "../../src/audio/node-socket.js";

/**
 * A stand-in for the `ws` WebSocket class.
 *
 * Standing up a real server would add a port, an async connect and a teardown
 * to every assertion here; none of that exercises the adapter, which is pure
 * translation. The fake records its constructor arguments and lets each `ws`
 * event be fired by hand, so the whole file is synchronous and deterministic.
 */
const fakeWs = vi.hoisted(() => {
  type Handler = (...args: unknown[]) => void;

  class FakeWebSocket {
    readonly sent: string[] = [];
    closes = 0;
    private readonly handlers = new Map<string, Handler>();

    constructor(
      readonly url: string,
      readonly options: { readonly headers: Record<string, string> },
    ) {
      instances.push(this);
    }

    on(event: string, handler: Handler): void {
      this.handlers.set(event, handler);
    }

    send(data: string): void {
      this.sent.push(data);
    }

    close(): void {
      this.closes += 1;
    }

    /** Delivers one `ws` event to whatever the adapter registered. */
    fire(event: string, ...args: unknown[]): void {
      this.handlers.get(event)?.(...args);
    }
  }

  const instances: FakeWebSocket[] = [];
  return { FakeWebSocket, instances };
});

vi.mock("ws", () => ({ default: fakeWs.FakeWebSocket }));

const lastSocket = (): InstanceType<typeof fakeWs.FakeWebSocket> => {
  const socket = fakeWs.instances.at(-1);
  if (socket === undefined) throw new Error("no socket was constructed");
  return socket;
};

beforeEach(() => {
  fakeWs.instances.length = 0;
});

describe("node websocket construction", () => {
  it("passes the url through unchanged", () => {
    const url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime";
    createNodeSocket(url, { "xi-api-key": "xi-secret" });
    expect(lastSocket().url).toBe(url);
  });

  it("carries the credential in a request header, never in the url", () => {
    // This is the property the whole adapter exists to provide. Node's global
    // WHATWG WebSocket cannot set headers, and the alternative ElevenLabs
    // offers is a `token` query parameter — a credential in a URL, which is
    // exactly the log-leak class this avoids. If this assertion ever fails,
    // the key is one error message away from being written to disk.
    const url = "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime";
    createNodeSocket(url, { "xi-api-key": "xi-secret" });

    expect(lastSocket().options.headers).toEqual({ "xi-api-key": "xi-secret" });
    expect(lastSocket().url).not.toContain("xi-secret");
    expect(lastSocket().url).not.toContain("token");
  });

  it("passes every header it is given", () => {
    createNodeSocket("wss://proxy.internal/stt", { "xi-api-key": "xi-secret", "user-agent": "aiur-streamdeck" });
    expect(lastSocket().options.headers).toEqual({
      "xi-api-key": "xi-secret",
      "user-agent": "aiur-streamdeck",
    });
  });

  it("copies the headers rather than handing the caller's object to ws", () => {
    const headers = { "xi-api-key": "xi-secret" };
    createNodeSocket("wss://api.elevenlabs.io/v1", headers);

    const given = lastSocket().options.headers;
    expect(given).toEqual(headers);
    // A shared object would let a later caller mutation reach an open socket.
    expect(given).not.toBe(headers);
  });

  it("returns a socket whose handlers all start unset", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    expect(adapter.onopen).toBeNull();
    expect(adapter.onmessage).toBeNull();
    expect(adapter.onerror).toBeNull();
    expect(adapter.onclose).toBeNull();
  });
});

describe("node websocket delegation", () => {
  it("sends through the underlying socket", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    adapter.send('{"message_type":"input_audio_chunk"}');
    adapter.send('{"message_type":"input_audio_chunk","audio_base_64":"aGk="}');

    expect(lastSocket().sent).toEqual([
      '{"message_type":"input_audio_chunk"}',
      '{"message_type":"input_audio_chunk","audio_base_64":"aGk="}',
    ]);
  });

  it("closes the underlying socket", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    adapter.close();
    expect(lastSocket().closes).toBe(1);
  });
});

describe("node websocket events", () => {
  it("reports the handshake completing", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const onopen = vi.fn();
    adapter.onopen = onopen;

    lastSocket().fire("open");

    expect(onopen).toHaveBeenCalledOnce();
  });

  it("decodes a frame from ws's Buffer into text", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const frames: { data: string }[] = [];
    adapter.onmessage = (event) => frames.push(event);

    const payload = JSON.stringify({ message_type: "committed_transcript", text: "hello" });
    lastSocket().fire("message", Buffer.from(payload, "utf8"));

    // A Node Buffer must not leak through the SocketLike boundary; the
    // transcriber parses a string.
    expect(frames).toEqual([{ data: payload }]);
    expect(typeof frames[0]?.data).toBe("string");
  });

  it("decodes multi-byte UTF-8 without splitting a character", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    let received: string | null = null;
    adapter.onmessage = (event) => {
      received = event.data;
    };

    // Transcripts routinely contain typographic punctuation and non-Latin
    // text; a latin1 decode here would corrupt every one of them.
    const payload = JSON.stringify({ text: "Kevin’s café — 東京 ☕" });
    lastSocket().fire("message", Buffer.from(payload, "utf8"));

    expect(received).toBe(payload);
    expect(JSON.parse(received ?? "{}")).toEqual({ text: "Kevin’s café — 東京 ☕" });
  });

  it("passes a transport error through", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const onerror = vi.fn();
    adapter.onerror = onerror;

    const failure = new Error("ECONNRESET");
    lastSocket().fire("error", failure);

    expect(onerror).toHaveBeenCalledWith(failure);
  });

  it("reports the socket closing", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const onclose = vi.fn();
    adapter.onclose = onclose;

    lastSocket().fire("close");

    expect(onclose).toHaveBeenCalledOnce();
  });

  it("ignores every event while its handler is still unset", () => {
    // The adapter is built before the transcriber attaches its handlers, so a
    // frame arriving in that window must not throw inside the ws event loop.
    createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const socket = lastSocket();

    expect(() => {
      socket.fire("open");
      socket.fire("message", Buffer.from("{}", "utf8"));
      socket.fire("error", new Error("ECONNRESET"));
      socket.fire("close");
    }).not.toThrow();
  });

  it("stops reporting once a handler is unset again", () => {
    const adapter = createNodeSocket("wss://api.elevenlabs.io/v1", {});
    const onmessage = vi.fn();
    adapter.onmessage = onmessage;

    lastSocket().fire("message", Buffer.from("{}", "utf8"));
    adapter.onmessage = null;
    lastSocket().fire("message", Buffer.from("{}", "utf8"));

    expect(onmessage).toHaveBeenCalledOnce();
  });
});
