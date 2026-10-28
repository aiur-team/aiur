import { expect, it, vi } from "vitest";
import { listSpeakers } from "../../src/audio/devices.js";
it("lists only PipeWire sinks and preserves descriptions", async () => {
  const run = vi.fn(async () => JSON.stringify([
    { info: { props: { "media.class": "Audio/Source", "node.name": "mic" } } },
    { info: { props: { "media.class": "Audio/Sink", "node.name": "speakers", "node.description": "Desk speakers" } } },
  ]));
  expect(await listSpeakers({ run, spawn: vi.fn() })).toEqual([{ id: "speakers", label: "Desk speakers" }]);
});
it("falls back to pactl sinks on PulseAudio hosts", async () => {
  const run = vi.fn(async (command: string) => {
    if (command === "pw-dump") throw new Error("not installed");
    return "1\tspeakers\tmodule\ts16le\tIDLE";
  });
  expect(await listSpeakers({ run, spawn: vi.fn() })).toEqual([{ id: "speakers", label: "speakers" }]);
  expect(run).toHaveBeenLastCalledWith("pactl", ["list", "sinks", "short"]);
});
