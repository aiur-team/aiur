import assert from "node:assert/strict";
import test from "node:test";

import { Pcm16Downsampler, toPcm16Sample } from "../src/browser.js";

test("PCM conversion clamps the signed 16-bit range", () => {
  assert.deepEqual(
    [-2, -1, -0.5, 0, 0.5, 1, 2].map(toPcm16Sample),
    [-32_768, -32_768, -16_384, 0, 16_384, 32_767, 32_767],
  );
});

test("downsampling preserves sample position across capture chunks", () => {
  const subject = new Pcm16Downsampler(8, 4);

  const first = subject.push(Float32Array.from([-1, -0.5, 0, 0.5, 1]));
  const second = subject.push(Float32Array.from([0.75, 0.5, 0.25, 0]));

  assert.deepEqual([...first], [-32_768, 0]);
  assert.deepEqual([...second], [32_767, 16_384]);
});

test("downsampling rejects unsupported sample rates", () => {
  assert.throws(() => new Pcm16Downsampler(16_000, 48_000), RangeError);
  assert.throws(() => new Pcm16Downsampler(0, 16_000), RangeError);
});
