import { it, expect, vi } from "vitest";
import { createFrameInput } from "../src/frame-input.js";

it("sends one raw key down per HID edge, then up without repainting", () => {
  const send = vi.fn(); const input = createFrameInput(send);
  const report = Uint8Array.from([1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]);
  input.handleReport(report); input.handleReport(report);
  expect(send.mock.calls).toEqual([[{ kind: "key", index: 0, action: "down" }]]);
  report[4] = 0; input.handleReport(report);
  expect(send.mock.calls[1]).toEqual([{ kind: "key", index: 0, action: "up" }]);
  report[4] = 1; input.handleReport(report); input.reset(); input.handleReport(report);
  expect(send).toHaveBeenCalledTimes(4);
});

it("forwards signed turns, dial press/long press and touch positions", () => {
  let now = 0; const send = vi.fn(); const input = createFrameInput(send, () => now);
  input.handleReport(Uint8Array.from([1, 3, 0, 0, 1, 255, 0, 0, 2]));
  expect(send.mock.calls).toEqual([[{ kind: "dial", index: 0, action: "turn", delta: -1 }], [{ kind: "dial", index: 3, action: "turn", delta: 2 }]]);
  input.handleReport(Uint8Array.from([1, 3, 0, 0, 0, 1]));
  input.handleReport(Uint8Array.from([1, 3, 0, 0, 0, 1]));
  now = 499; input.handleReport(Uint8Array.from([1, 3, 0, 0, 0, 0]));
  expect(send).toHaveBeenLastCalledWith({ kind: "dial", index: 0, action: "press" });
  input.handleReport(Uint8Array.from([1, 3, 0, 0, 0, 1]));
  now = 999; input.handleReport(Uint8Array.from([1, 3, 0, 0, 0, 0]));
  expect(send).toHaveBeenLastCalledWith({ kind: "dial", index: 0, action: "long_press" });
  input.handleReport(Uint8Array.from([1, 2, 0, 0, 0, 0, 255, 1, 0, 0]));
  expect(send).toHaveBeenLastCalledWith({ kind: "touch", index: 2, action: "tap", x: 511 });
  const count = send.mock.calls.length;
  for (const report of [[], [0, 2, 0, 0, 0, 0, 255, 1, 0, 0], [1, 2, 0, 0, 0], [1, 2, 0, 0, 1, 0, 255, 1, 0, 0], [1, 2, 0, 0, 0, 0, 32, 3, 0, 0]]) input.handleReport(Uint8Array.from(report));
  expect(send).toHaveBeenCalledTimes(count);
});
