/**
 * The Node implementation of the audio stack's HTTP fetch port.
 *
 * Like `node-system.ts` and `node-socket.ts`, this is an adapter with no
 * decisions in it: it translates the platform `fetch` + `ReadableStream`
 * into the `FetchLike` port the TTS provider is written against, so the
 * provider stays free of web/Node transport types.
 */

import type { FetchLike, FetchResponse } from "./elevenlabs-tts.js";

export const createNodeFetch: FetchLike = async (url, init) => {
  const response = await fetch(url, {
    method: init.method,
    headers: { ...init.headers },
    body: init.body,
  });

  const stream: FetchResponse["stream"] = async function* () {
    const body = response.body;
    if (body === null) {
      return;
    }
    const reader = body.getReader();
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) {
          return;
        }
        yield value;
      }
    } finally {
      reader.releaseLock();
    }
  };

  return { ok: response.ok, status: response.status, stream };
};
