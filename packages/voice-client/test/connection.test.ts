import assert from "node:assert/strict";
import test from "node:test";

import {
  VoiceClientError,
  connectVoiceWire,
  type VoiceSocket,
  type VoiceSocketFactory,
  type WireCodec,
} from "../src/index.js";

type Outbound = { readonly kind: "start" | "text"; readonly text?: string };
type Inbound = { readonly kind: "state" | "transcript"; readonly text?: string };

class SocketHarness implements VoiceSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: { readonly data: unknown }) => void) | null = null;
  onerror: ((error: unknown) => void) | null = null;
  onclose: (() => void) | null = null;
  readonly sent: string[] = [];
  readonly closes: Array<{ readonly code?: number; readonly reason?: string }> = [];

  send(data: string): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closes.push({ code, reason });
  }

  open(): void {
    this.onopen?.();
  }

  message(data: unknown): void {
    this.onmessage?.({ data });
  }

  error(error: unknown): void {
    this.onerror?.(error);
  }

  closed(): void {
    this.onclose?.();
  }
}

const codec: WireCodec<Outbound, Inbound> = {
  encodeOutbound(frame) {
    if (frame.kind === "text" && !frame.text) throw new Error("schema rejected outbound frame");
    return JSON.stringify(frame);
  },
  decodeInbound(data) {
    if (typeof data !== "string") throw new Error("schema rejected inbound frame");
    const frame = JSON.parse(data) as Partial<Inbound>;
    if (frame.kind !== "state" && frame.kind !== "transcript") throw new Error("schema rejected inbound frame");
    return frame as Inbound;
  },
};

const harness = () => {
  const socket = new SocketHarness();
  const factoryCalls: Array<{ readonly endpoint: string; readonly token: string }> = [];
  const factory: VoiceSocketFactory = (options) => {
    factoryCalls.push(options);
    return socket;
  };
  const states: string[] = [];
  const frames: Inbound[] = [];
  const errors: VoiceClientError[] = [];
  const connection = connectVoiceWire({
    endpoint: "ws://voice.test/session",
    token: "host-issued-secret",
    socketFactory: factory,
    codec,
    events: {
      stateChanged: (state) => states.push(state),
      frame: (frame) => frames.push(frame),
      error: (error) => errors.push(error),
    },
  });
  return { socket, factoryCalls, states, frames, errors, connection };
};

test("queues schema-valid frames until the socket opens", () => {
  const subject = harness();
  subject.connection.send({ kind: "start" });
  subject.connection.send({ kind: "text", text: "hello" });
  assert.deepEqual(subject.socket.sent, []);

  subject.socket.open();

  assert.deepEqual(subject.socket.sent.map((value) => JSON.parse(value)), [
    { kind: "start" },
    { kind: "text", text: "hello" },
  ]);
  assert.deepEqual(subject.states, ["connecting", "open"]);
  assert.equal(subject.connection.state, "open");
});

test("rejects an invalid outbound frame before it reaches the socket", () => {
  const subject = harness();
  subject.socket.open();

  assert.throws(() => subject.connection.send({ kind: "text" }), (error: unknown) => {
    assert.ok(error instanceof VoiceClientError);
    assert.equal(error.code, "protocol_error");
    assert.doesNotMatch(error.message, /schema rejected outbound frame/);
    return true;
  });
  assert.deepEqual(subject.socket.sent, []);
});

test("delivers only schema-valid inbound frames", () => {
  const subject = harness();
  subject.socket.open();
  subject.socket.message(JSON.stringify({ kind: "transcript", text: "heard" }));

  assert.deepEqual(subject.frames, [{ kind: "transcript", text: "heard" }]);
  assert.deepEqual(subject.errors, []);
});

test("turns malformed inbound data into a redacted terminal protocol error", () => {
  const subject = harness();
  subject.socket.open();
  subject.socket.message("not-json-host-issued-secret");

  assert.deepEqual(subject.frames, []);
  assert.equal(subject.connection.state, "failed");
  assert.equal(subject.errors.length, 1);
  assert.equal(subject.errors[0]?.code, "protocol_error");
  assert.doesNotMatch(subject.errors[0]?.message ?? "", /host-issued-secret/);
  assert.deepEqual(subject.socket.closes, [{ code: 1002, reason: "protocol error" }]);
});

test("turns socket failures into redacted transport errors", () => {
  const subject = harness();
  subject.socket.error(new Error("failed ws://voice.test/session?token=host-issued-secret"));

  assert.equal(subject.connection.state, "failed");
  assert.equal(subject.errors[0]?.code, "transport_error");
  assert.doesNotMatch(subject.errors[0]?.message ?? "", /voice[.]test|host-issued-secret/);
});

test("closes once and rejects sends after closing", () => {
  const subject = harness();
  subject.socket.open();
  subject.connection.close();
  subject.connection.close();

  assert.deepEqual(subject.socket.closes, [{ code: 1000, reason: "client closed" }]);
  assert.equal(subject.connection.state, "closing");
  assert.throws(() => subject.connection.send({ kind: "start" }), (error: unknown) => {
    assert.ok(error instanceof VoiceClientError);
    assert.equal(error.code, "connection_not_open");
    return true;
  });

  subject.socket.closed();
  assert.equal(subject.connection.state, "closed");
});

test("passes the host token only to the socket factory", () => {
  const subject = harness();

  assert.deepEqual(subject.factoryCalls, [{ endpoint: "ws://voice.test/session", token: "host-issued-secret" }]);
  assert.equal("token" in subject.connection, false);
  assert.equal(JSON.stringify(subject.connection).includes("host-issued-secret"), false);
});

test("rejects blank endpoints and tokens before constructing a socket", () => {
  for (const options of [
    { endpoint: "", token: "issued" },
    { endpoint: "ws://voice.test/session", token: "  " },
  ]) {
    let factoryCalled = false;
    assert.throws(
      () => connectVoiceWire({
        ...options,
        socketFactory: () => {
          factoryCalled = true;
          return new SocketHarness();
        },
        codec,
      }),
      (error: unknown) => {
        assert.ok(error instanceof VoiceClientError);
        assert.equal(error.code, "connection_failed");
        return true;
      },
    );
    assert.equal(factoryCalled, false);
  }
});
