/**
 * The Node websocket adapter for the voice stack.
 *
 * Node's global WHATWG `WebSocket` accepts only `(url, protocols)` and has no
 * option for request headers, so it cannot carry the `xi-api-key` header the
 * transcription endpoint authenticates with. The `ws` package can, and is what
 * ElevenLabs' own server-side Node guide tells you to install. It is pure
 * JavaScript with zero runtime dependencies and no build step — its
 * `bufferutil`/`utf-8-validate` accelerators are genuinely optional peer
 * dependencies that we never ship — so it is safe for a tarball that carries a
 * bundled runtime and no toolchain.
 *
 * The alternative, a single-use token in the `token` query parameter, is the
 * *browser* answer: it still puts a credential in a URL, which is the log-leak
 * class we are avoiding, and because the token is consumed on use it would
 * force a REST round trip before every reconnect.
 *
 * Like `node-system.ts`, this file is an adapter with no decisions in it, and
 * it is the only part of the stack that knows which websocket library is used.
 */

import WebSocket from "ws";
import type { SocketFactory, SocketLike } from "./stt.js";

export const createNodeSocket: SocketFactory = (url, headers): SocketLike => {
  const socket = new WebSocket(url, { headers: { ...headers } });

  const adapter: SocketLike = {
    onopen: null,
    onmessage: null,
    onerror: null,
    onclose: null,
    send(data: string): void {
      socket.send(data);
    },
    close(): void {
      socket.close();
    },
  };

  socket.on("open", () => adapter.onopen?.());
  // Frames are JSON text. `ws` hands over a Buffer regardless, so it is decoded
  // here rather than leaking a Node type through the SocketLike boundary.
  socket.on("message", (data: Buffer) => adapter.onmessage?.({ data: data.toString("utf8") }));
  socket.on("error", (error: Error) => adapter.onerror?.(error));
  socket.on("close", () => adapter.onclose?.());

  return adapter;
};
