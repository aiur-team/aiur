/**
 * The settings surface's pure view model: which microphone sits on which key.
 *
 * Six of the eight physical keys are microphones, so a machine with more than
 * six sources has to page. Paging is a *device* offset rather than a page
 * number so a caller can move by one device if a later surface ever wants to,
 * but every function here snaps the offset to a page boundary — a half-scrolled
 * page would put a device on a different key each time the list is re-read, and
 * the key an operator learned would stop meaning what it meant.
 *
 * Nothing here talks to PulseAudio, the deck, or a preference file. It takes
 * the device list and the remembered selection and returns what to paint.
 */

import type { AudioDevice } from "./audio/index.js";

/** Microphone keys on the settings surface; keys 6 and 7 are TestMic and paging. */
export const MICS_PER_PAGE = 6;

export interface MicSlot {
  readonly id: string;
  readonly label: string;
  /** True for the microphone capture will actually open. */
  readonly selected: boolean;
}

export interface SettingsView {
  /** Exactly {@link MICS_PER_PAGE} entries; `null` is a key with no device. */
  readonly mics: readonly (MicSlot | null)[];
  /** True when there are more microphones than one page can show. */
  readonly hasPaging: boolean;
  /** Human page position, e.g. `"2/3"`. Always `"1/1"` when paging is off. */
  readonly pageLabel: string;
}

/** How many pages `count` devices occupy. Zero devices is still one (empty) page. */
const pageCount = (count: number): number => Math.max(1, Math.ceil(count / MICS_PER_PAGE));

/**
 * The first device index of the page `offset` falls in, wrapped into range.
 *
 * A stale offset is normal rather than exceptional: the operator pages to the
 * third screen, unplugs a USB interface, and the list is now one page long. It
 * wraps instead of throwing, so an unplug re-reads as page one rather than as a
 * blank surface.
 */
const pageStart = (offset: number, count: number): number => {
  if (count <= MICS_PER_PAGE) return 0;
  const page = Math.floor(Math.max(0, offset) / MICS_PER_PAGE) % pageCount(count);
  return page * MICS_PER_PAGE;
};

/**
 * The six microphone keys for one page.
 *
 * An empty device list is a legitimate state — a headless box has no
 * microphone, and `listMicrophones` returns `[]` on every failure path — so it
 * produces six empty slots rather than an error. The panel beside these keys is
 * what says "No microphones"; the keys themselves simply have nothing on them.
 */
export function settingsView(
  devices: readonly AudioDevice[],
  selectedId: string | null,
  offset: number,
): SettingsView {
  const start = pageStart(offset, devices.length);
  const hasPaging = devices.length > MICS_PER_PAGE;
  const mics = Array.from({ length: MICS_PER_PAGE }, (_, slot): MicSlot | null => {
    const device = devices[start + slot];
    if (device === undefined) return null;
    return { id: device.id, label: device.label, selected: device.id === selectedId };
  });

  return {
    mics,
    hasPaging,
    pageLabel: `${start / MICS_PER_PAGE + 1}/${pageCount(devices.length)}`,
  };
}

/** The offset of the next page, wrapping past the last one back to the first. */
export function nextMicPage(offset: number, deviceCount: number): number {
  if (deviceCount <= MICS_PER_PAGE) return 0;
  return (pageStart(offset, deviceCount) + MICS_PER_PAGE) % (pageCount(deviceCount) * MICS_PER_PAGE);
}

/**
 * The device on key `slot` of the page at `offset`, or undefined for an empty
 * key. Shares {@link pageStart} with {@link settingsView} so a press cannot
 * address a different device than the one that was painted.
 */
export function micAtSlot(
  devices: readonly AudioDevice[],
  offset: number,
  slot: number,
): AudioDevice | undefined {
  if (slot < 0 || slot >= MICS_PER_PAGE) return undefined;
  return devices[pageStart(offset, devices.length) + slot];
}
