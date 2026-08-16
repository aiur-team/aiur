import { describe, expect, it, vi } from "vitest";
import { PACTL, PW_DUMP, listMicrophones } from "../../src/audio/devices.js";
import type { SystemPort } from "../../src/audio/system.js";

type RunResult = string | Error;

interface RunHarness {
  readonly system: SystemPort;
  readonly calls: { command: string; args: readonly string[] }[];
}

/**
 * A `SystemPort` scripted per command, so a test can make `pw-dump` fail while
 * `pactl` answers — which is the whole point of the fallback.
 */
const runHarness = (results: Readonly<Record<string, RunResult>>): RunHarness => {
  const calls: { command: string; args: readonly string[] }[] = [];
  return {
    calls,
    system: {
      run: (command, args) => {
        calls.push({ command, args });
        const result = results[command];
        if (result === undefined) return Promise.reject(new Error(`spawn ${command} ENOENT`));
        if (result instanceof Error) return Promise.reject(result);
        return Promise.resolve(result);
      },
      spawn: () => {
        throw new Error("listMicrophones must not spawn");
      },
    },
  };
};

/** One `pw-dump` node, trimmed to the shape the parser reads. */
const pipeWireNode = (props: Readonly<Record<string, unknown>>): unknown => ({
  id: 51,
  type: "PipeWire:Interface:Node",
  info: { props },
});

const source = (name: string, description?: string): unknown =>
  pipeWireNode({
    "media.class": "Audio/Source",
    "node.name": name,
    ...(description === undefined ? {} : { "node.description": description }),
  });

describe("microphone discovery via pw-dump", () => {
  it("asks pw-dump first, with no arguments", async () => {
    const harness = runHarness({ [PW_DUMP]: "[]" });
    await listMicrophones(harness.system);
    expect(harness.calls).toEqual([{ command: PW_DUMP, args: [] }]);
  });

  it("maps capture nodes to id and human label", async () => {
    const raw = JSON.stringify([source("alsa_input.yeti", "Yeti X Analog Stereo"), source("bluez_input.ac_12", "WH-1000XM4")]);
    const devices = await listMicrophones(runHarness({ [PW_DUMP]: raw }).system);
    expect(devices).toEqual([
      { id: "alsa_input.yeti", label: "Yeti X Analog Stereo" },
      { id: "bluez_input.ac_12", label: "WH-1000XM4" },
    ]);
  });

  it("keeps a non-ASCII description intact", async () => {
    // This is the bug pw-dump exists to avoid: `pactl -f json` on libpulse 17.0
    // returns the literal "(null)" for a description containing U+2019.
    const raw = JSON.stringify([source("bluez_input.ac_12", "Kevin’s AirPods Pro")]);
    const devices = await listMicrophones(runHarness({ [PW_DUMP]: raw }).system);
    expect(devices).toEqual([{ id: "bluez_input.ac_12", label: "Kevin’s AirPods Pro" }]);
    expect(devices[0]?.label).not.toContain("(null)");
  });

  it("keeps only capture nodes, so monitors never appear", async () => {
    const raw = JSON.stringify([
      pipeWireNode({ "media.class": "Audio/Sink", "node.name": "alsa_output.hdmi", "node.description": "HDMI" }),
      pipeWireNode({ "media.class": "Stream/Output/Audio", "node.name": "firefox" }),
      source("alsa_input.yeti", "Yeti X"),
    ]);
    // A monitor is a loopback of an output; transcribing one would fill the
    // panel with whatever the operator was listening to.
    const devices = await listMicrophones(runHarness({ [PW_DUMP]: raw }).system);
    expect(devices).toEqual([{ id: "alsa_input.yeti", label: "Yeti X" }]);
  });

  it("skips objects that carry no props at all", async () => {
    // pw-dump lists every interface, most of which are not nodes.
    const raw = JSON.stringify([
      { id: 0, type: "PipeWire:Interface:Core" },
      { id: 12, type: "PipeWire:Interface:Node", info: {} },
      source("alsa_input.yeti", "Yeti X"),
    ]);
    const devices = await listMicrophones(runHarness({ [PW_DUMP]: raw }).system);
    expect(devices).toEqual([{ id: "alsa_input.yeti", label: "Yeti X" }]);
  });

  it("skips a capture node with no usable name", async () => {
    const raw = JSON.stringify([
      pipeWireNode({ "media.class": "Audio/Source" }),
      pipeWireNode({ "media.class": "Audio/Source", "node.name": "   " }),
      pipeWireNode({ "media.class": "Audio/Source", "node.name": 42 }),
    ]);
    expect(await listMicrophones(runHarness({ [PW_DUMP]: raw }).system)).toEqual([]);
  });

  it("falls back to the id when the description is missing, blank or not text", async () => {
    const raw = JSON.stringify([
      source("alsa_input.nodesc"),
      source("alsa_input.blank", "   "),
      pipeWireNode({ "media.class": "Audio/Source", "node.name": "alsa_input.nonstring", "node.description": 7 }),
    ]);
    const devices = await listMicrophones(runHarness({ [PW_DUMP]: raw }).system);
    expect(devices).toEqual([
      { id: "alsa_input.nodesc", label: "alsa_input.nodesc" },
      { id: "alsa_input.blank", label: "alsa_input.blank" },
      { id: "alsa_input.nonstring", label: "alsa_input.nonstring" },
    ]);
  });

  it("trims the whitespace PipeWire pads properties with", async () => {
    const raw = JSON.stringify([source("  alsa_input.yeti  ", "  Yeti X  ")]);
    expect(await listMicrophones(runHarness({ [PW_DUMP]: raw }).system)).toEqual([
      { id: "alsa_input.yeti", label: "Yeti X" },
    ]);
  });

  it("accepts an empty PipeWire graph as a real answer and does not fall back", async () => {
    // A host with no microphone attached is not a failure to enumerate.
    const harness = runHarness({ [PW_DUMP]: "[]", [PACTL]: "1\talsa_input.yeti\tmodule\ts16le\tSUSPENDED" });
    expect(await listMicrophones(harness.system)).toEqual([]);
    expect(harness.calls.map((call) => call.command)).toEqual([PW_DUMP]);
  });
});

describe("microphone discovery via the pactl fallback", () => {
  it("falls back when pw-dump is not installed", async () => {
    const harness = runHarness({
      [PACTL]: ["0\talsa_input.yeti\tmodule-alsa-card.c\ts16le 1ch 16000Hz\tSUSPENDED"].join("\n"),
    });
    const devices = await listMicrophones(harness.system);

    expect(devices).toEqual([{ id: "alsa_input.yeti", label: "alsa_input.yeti" }]);
    expect(harness.calls).toEqual([
      { command: PW_DUMP, args: [] },
      { command: PACTL, args: ["list", "sources", "short"] },
    ]);
  });

  it("falls back when pw-dump emits something that is not JSON", async () => {
    const harness = runHarness({
      [PW_DUMP]: "remote 0 is not running",
      [PACTL]: "0\talsa_input.yeti\tmodule\ts16le\tSUSPENDED",
    });
    expect(await listMicrophones(harness.system)).toEqual([{ id: "alsa_input.yeti", label: "alsa_input.yeti" }]);
    expect(harness.calls.map((call) => call.command)).toEqual([PW_DUMP, PACTL]);
  });

  it("falls back when pw-dump emits valid JSON that is not a node list", async () => {
    const harness = runHarness({ [PW_DUMP]: '{"error":"no session"}', [PACTL]: "0\talsa_input.yeti\tmodule\ts16le\tIDLE" });
    expect(await listMicrophones(harness.system)).toEqual([{ id: "alsa_input.yeti", label: "alsa_input.yeti" }]);
  });

  it("strips monitors by the .monitor suffix PulseAudio guarantees them", async () => {
    const listing = [
      "0\talsa_output.hdmi.monitor\tmodule\ts16le\tSUSPENDED",
      "1\talsa_input.yeti\tmodule\ts16le\tSUSPENDED",
    ].join("\n");
    const devices = await listMicrophones(runHarness({ [PACTL]: listing }).system);
    expect(devices).toEqual([{ id: "alsa_input.yeti", label: "alsa_input.yeti" }]);
  });

  it("ignores blank and malformed lines in the short listing", async () => {
    const listing = ["", "0\talsa_input.yeti\tmodule\ts16le\tSUSPENDED", "no-tabs-here", "1\t   \tmodule", ""].join("\n");
    const devices = await listMicrophones(runHarness({ [PACTL]: listing }).system);
    expect(devices).toEqual([{ id: "alsa_input.yeti", label: "alsa_input.yeti" }]);
  });

  it("reports no microphones when neither tool is available", async () => {
    // A headless box has no sound server at all; the sidecar must still start.
    const harness = runHarness({});
    expect(await listMicrophones(harness.system)).toEqual([]);
    expect(harness.calls.map((call) => call.command)).toEqual([PW_DUMP, PACTL]);
  });

  it("reports no microphones when pactl fails after pw-dump was unparseable", async () => {
    const harness = runHarness({ [PW_DUMP]: "<html>", [PACTL]: new Error("Connection refused") });
    expect(await listMicrophones(harness.system)).toEqual([]);
  });

  it("reports no microphones for an empty short listing", async () => {
    expect(await listMicrophones(runHarness({ [PACTL]: "" }).system)).toEqual([]);
  });
});

describe("discovery never spawns", () => {
  it("uses run, so no long-lived process is left behind", async () => {
    const spawn = vi.fn();
    await listMicrophones({ run: () => Promise.reject(new Error("no")), spawn });
    expect(spawn).not.toHaveBeenCalled();
  });
});
