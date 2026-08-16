/**
 * Microphone discovery.
 *
 * This box runs PipeWire with the PulseAudio compatibility layer, so both
 * `pw-dump` and `pactl` can see the sources. `pw-dump` is preferred for three
 * measured reasons:
 *
 *  - `pactl -f json` is UTF-8-broken in libpulse 17.0. A source whose
 *    description contains a non-ASCII character (an AirPods name with a
 *    typographic apostrophe, say) comes back as the literal `"(null)"` with
 *    parse errors on stderr. `pw-dump` reports it correctly.
 *  - Monitor sources are structurally absent from a `media.class` filter,
 *    rather than needing to be recognised and stripped. Monitors are loopbacks
 *    of an output; offering one would let the operator "record" their own
 *    speakers and wonder why the transcript is full of what they were
 *    listening to.
 *  - `arecord -l` is not an option at all: it lists ALSA cards that have no
 *    corresponding source, and it misses Bluetooth microphones entirely.
 *
 * `pactl list sources short` remains as a fallback for a PulseAudio host with
 * no PipeWire, where the same UTF-8 bug does not apply because the short
 * listing carries no description.
 *
 * A native Node binding was rejected: the sidecar ships as a tarball with a
 * bundled Node runtime and no build toolchain, so a node-gyp dependency is
 * another way for an install to fail on a machine we cannot inspect. The two
 * PortAudio bindings do not compile on Node 24, and every native option routes
 * through ALSA, which PipeWire holds exclusively here.
 */

import type { SystemPort } from "./system.js";

export interface AudioDevice {
  /** Stable node/source name, passed straight back to the recorder. */
  readonly id: string;
  /** Human label for the key face, e.g. "Yeti X Analog Stereo". */
  readonly label: string;
}

export const PW_DUMP = "pw-dump";
export const PACTL = "pactl";

/** PipeWire's class for a capture node. Sinks and their monitors are not this. */
const SOURCE_CLASS = "Audio/Source";

interface PipeWireNode {
  readonly info?: { readonly props?: Readonly<Record<string, unknown>> };
}

const stringProp = (props: Readonly<Record<string, unknown>>, key: string): string => {
  const value = props[key];
  return typeof value === "string" ? value.trim() : "";
};

/** Parses `pw-dump` output; returns null when it is unusable so we can fall back. */
function parsePipeWire(raw: string): AudioDevice[] | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!Array.isArray(parsed)) return null;

  const devices: AudioDevice[] = [];
  for (const node of parsed as PipeWireNode[]) {
    const props = node.info?.props;
    if (props === undefined) continue;
    if (stringProp(props, "media.class") !== SOURCE_CLASS) continue;

    const id = stringProp(props, "node.name");
    if (id === "") continue;
    const description = stringProp(props, "node.description");
    devices.push({ id, label: description === "" ? id : description });
  }
  return devices;
}

/**
 * Parses `pactl list sources short`: tab-separated index, name, driver, format,
 * state. Monitors are not distinguishable by class here, so they are stripped
 * by the `.monitor` name suffix that PulseAudio guarantees them.
 */
function parsePulseShort(raw: string): AudioDevice[] {
  const devices: AudioDevice[] = [];
  for (const line of raw.split("\n")) {
    const id = line.split("\t")[1]?.trim() ?? "";
    if (id === "" || id.endsWith(".monitor")) continue;
    devices.push({ id, label: id });
  }
  return devices;
}

/**
 * Lists attached hardware microphones, best label first.
 *
 * An empty list is a legitimate state — a headless box has no microphone — so
 * every failure path returns one rather than throwing. The settings pane says
 * "no microphones" instead of the sidecar failing to start.
 */
export async function listMicrophones(system: SystemPort): Promise<AudioDevice[]> {
  try {
    const devices = parsePipeWire(await system.run(PW_DUMP, []));
    // A PipeWire host with zero capture nodes is a real answer, so an empty
    // array is returned as-is; only unparseable output falls through.
    if (devices !== null) return devices;
  } catch {
    // pw-dump missing means this is not a PipeWire host; try the Pulse tools.
  }

  try {
    return parsePulseShort(await system.run(PACTL, ["list", "sources", "short"]));
  } catch {
    return [];
  }
}
