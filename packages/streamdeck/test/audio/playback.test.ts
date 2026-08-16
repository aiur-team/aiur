import { describe, expect, it } from "vitest";
import { playEncodedAudio, type PlaybackPort } from "../../src/audio/playback.js";

describe("playEncodedAudio", () => {
  it("writes every chunk and closes the port once on success", async () => {
    const writes: Uint8Array[] = [];
    let closes = 0;
    const port: PlaybackPort = {
      write(chunk) {
        writes.push(chunk);
      },
      close() {
        closes += 1;
      },
    };
    const audio = (async function* () {
      yield new Uint8Array([1]);
      yield new Uint8Array([2]);
    })();

    await playEncodedAudio(port, audio);

    expect(writes).toEqual([new Uint8Array([1]), new Uint8Array([2])]);
    expect(closes).toBe(1);
  });

  it("closes the port and propagates the error when the stream throws", async () => {
    const writes: Uint8Array[] = [];
    let closes = 0;
    const port: PlaybackPort = {
      write(chunk) {
        writes.push(chunk);
      },
      close() {
        closes += 1;
      },
    };
    const audio = (async function* () {
      yield new Uint8Array([1]);
      throw new Error("boom");
    })();

    await expect(playEncodedAudio(port, audio)).rejects.toThrow("boom");

    expect(writes).toEqual([new Uint8Array([1])]);
    expect(closes).toBe(1);
  });

  it("awaits asynchronous writes and closes after the last one", async () => {
    const order: string[] = [];
    const port: PlaybackPort = {
      async write() {
        order.push("write");
      },
      async close() {
        order.push("close");
      },
    };
    const audio = (async function* () {
      yield new Uint8Array([1]);
    })();

    await playEncodedAudio(port, audio);

    expect(order).toEqual(["write", "close"]);
  });
});
