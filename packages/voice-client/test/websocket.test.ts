import assert from "node:assert/strict";
import test from "node:test";

import { createQueryTokenSocketFactory, type VoiceSocket } from "../src/index.js";

class FakeUrl {
  readonly searchParams = {
    set: (key: string, value: string) => {
      this.params.set(key, value);
    },
  };
  private readonly params = new Map<string, string>();

  constructor(private readonly endpoint: string) {}

  toString(): string {
    const separator = this.endpoint.includes("?") ? "&" : "?";
    const query = [...this.params].map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&");
    return `${this.endpoint}${separator}${query}`;
  }
}

class FakeWebSocket implements VoiceSocket {
  static readonly urls: string[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((event: { readonly data: unknown }) => void) | null = null;
  onerror: ((error: unknown) => void) | null = null;
  onclose: (() => void) | null = null;

  constructor(url: string) {
    FakeWebSocket.urls.push(url);
  }

  send(_data: string): void {}
  close(_code?: number, _reason?: string): void {}
}

class ThrowingWebSocket extends FakeWebSocket {
  constructor(url: string) {
    super(url);
    throw new Error(`could not open ${url}`);
  }
}

test("query-token socket factory preserves the endpoint and percent-encodes the issued token", () => {
  FakeWebSocket.urls.length = 0;
  const factory = createQueryTokenSocketFactory({
    Url: FakeUrl,
    WebSocket: FakeWebSocket,
  });

  factory({ endpoint: "wss://voice.test/session?locale=en", token: "issued token/+" });

  assert.deepEqual(FakeWebSocket.urls, ["wss://voice.test/session?locale=en&token=issued%20token%2F%2B"]);
});

test("default factory fails safely when no WebSocket implementation exists", () => {
  const factory = createQueryTokenSocketFactory({ Url: FakeUrl, WebSocket: undefined });

  assert.throws(
    () => factory({ endpoint: "wss://voice.test/session", token: "must-not-appear" }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.doesNotMatch(error.message, /must-not-appear/);
      return true;
    },
  );
});

test("socket construction failures do not expose the token-bearing URL", () => {
  const factory = createQueryTokenSocketFactory({ Url: FakeUrl, WebSocket: ThrowingWebSocket });

  assert.throws(
    () => factory({ endpoint: "wss://voice.test/session", token: "must-not-appear" }),
    (error: unknown) => {
      assert.ok(error instanceof Error);
      assert.doesNotMatch(error.message, /voice[.]test|must-not-appear/);
      return true;
    },
  );
});
