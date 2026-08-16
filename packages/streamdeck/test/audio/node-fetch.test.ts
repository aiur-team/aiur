import { describe, expect, it, vi } from "vitest";
import { createNodeFetch } from "../../src/audio/node-fetch.js";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const concat = (chunks: Uint8Array[]): Uint8Array => {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
};

describe("createNodeFetch", () => {
  it("maps a successful response into a byte stream", async () => {
    vi.stubGlobal("fetch", async () => new Response(encoder.encode("abc"), { status: 200 }));
    try {
      const response = await createNodeFetch("https://x.test/a", {
        method: "POST",
        headers: { "xi-api-key": "k" },
        body: "{}",
      });

      expect(response.ok).toBe(true);
      expect(response.status).toBe(200);

      const chunks: Uint8Array[] = [];
      for await (const chunk of response.stream()) {
        chunks.push(chunk);
      }
      expect(decoder.decode(concat(chunks))).toBe("abc");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("passes the method, headers, and body through to the platform fetch", async () => {
    let captured: { url: unknown; init: Record<string, unknown> } | undefined;
    vi.stubGlobal("fetch", async (url: unknown, init: Record<string, unknown>) => {
      captured = { url, init };
      return new Response(null, { status: 204 });
    });
    try {
      await createNodeFetch("https://x.test/b", {
        method: "PUT",
        headers: { h: "1" },
        body: "{}",
      });

      expect(captured?.url).toBe("https://x.test/b");
      expect(captured?.init.method).toBe("PUT");
      expect(captured?.init.headers).toEqual({ h: "1" });
      expect(captured?.init.body).toBe("{}");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("reports a failure status and yields nothing when the response has no body", async () => {
    vi.stubGlobal("fetch", async () => new Response(null, { status: 401 }));
    try {
      const response = await createNodeFetch("https://x.test/c", {
        method: "POST",
        headers: {},
        body: "{}",
      });

      expect(response.ok).toBe(false);
      expect(response.status).toBe(401);

      const chunks: Uint8Array[] = [];
      for await (const chunk of response.stream()) {
        chunks.push(chunk);
      }
      expect(chunks).toEqual([]);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
