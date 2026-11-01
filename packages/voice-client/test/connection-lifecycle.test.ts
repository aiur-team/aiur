import assert from "node:assert/strict";
import test from "node:test";

import {
  connectVoiceWire,
  type VoiceClientError,
  type VoiceConnectionState,
  type VoiceSocket,
} from "../src/index.js";

class SocketHarness implements VoiceSocket {
  onopen: (() => void) | null = null;
  onmessage: ((event: { readonly data: unknown }) => void) | null = null;
  onerror: ((error: unknown) => void) | null = null;
  onclose: (() => void) | null = null;
  send(_data: string): void {}
  close(_code?: number, _reason?: string): void {}
}

const harness = () => {
  const socket = new SocketHarness();
  const errors: VoiceClientError[] = [];
  const states: VoiceConnectionState[] = [];
  const connection = connectVoiceWire({
    endpoint: "wss://voice.test/session",
    token: "issued",
    socketFactory: () => socket,
    codec: {
      encodeOutbound: JSON.stringify,
      decodeInbound: (data) => data,
    },
    events: {
      error: (error) => errors.push(error),
      stateChanged: (state) => states.push(state),
    },
  });
  return { connection, socket, errors, states };
};

test("an unexpected socket close reports a transport failure", () => {
  const subject = harness();
  subject.socket.onopen?.();

  subject.socket.onclose?.();

  assert.equal(subject.connection.state, "failed");
  assert.equal(subject.errors[0]?.code, "transport_error");
  assert.deepEqual(subject.states, ["connecting", "open", "failed"]);
});

test("socket errors after a requested close do not replace the closed state", () => {
  const subject = harness();
  subject.socket.onopen?.();
  subject.connection.close();

  subject.socket.onerror?.(new Error("late transport error"));
  subject.socket.onclose?.();

  assert.equal(subject.connection.state, "closed");
  assert.deepEqual(subject.errors, []);
  assert.deepEqual(subject.states, ["connecting", "open", "closing", "closed"]);
});
