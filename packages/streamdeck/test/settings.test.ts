import { describe, expect, it } from "vitest";

import { MICS_PER_PAGE, micAtSlot, nextMicPage, settingsView } from "../src/settings.js";
import type { AudioDevice } from "../src/audio/index.js";

const devices = (count: number): AudioDevice[] =>
  Array.from({ length: count }, (_, index) => ({ id: `mic-${index}`, label: `Mic ${index}` }));

const labels = (view: ReturnType<typeof settingsView>): (string | null)[] =>
  view.mics.map((slot) => slot?.label ?? null);

describe("settingsView", () => {
  it("always fills exactly one page of key slots", () => {
    for (const count of [0, 1, 6, 7, 20]) {
      expect(settingsView(devices(count), null, 0).mics).toHaveLength(MICS_PER_PAGE);
    }
  });

  it("puts the first six devices on the first page and pads the rest", () => {
    const view = settingsView(devices(2), null, 0);
    expect(labels(view)).toEqual(["Mic 0", "Mic 1", null, null, null, null]);
    expect(view.hasPaging).toBe(false);
    expect(view.pageLabel).toBe("1/1");
  });

  // A headless box has no microphone and `listMicrophones` returns [] on every
  // failure path, so this is a state the surface has to render, not an error.
  it("renders an empty device list as six empty slots on a single page", () => {
    const view = settingsView([], null, 0);
    expect(labels(view)).toEqual([null, null, null, null, null, null]);
    expect(view).toMatchObject({ hasPaging: false, pageLabel: "1/1" });
  });

  it("marks exactly the selected device, and none when the choice is gone", () => {
    expect(settingsView(devices(3), "mic-1", 0).mics.map((slot) => slot?.selected)).toEqual([
      false,
      true,
      false,
      undefined,
      undefined,
      undefined,
    ]);
    expect(settingsView(devices(3), "mic-9", 0).mics.some((slot) => slot?.selected === true)).toBe(false);
    expect(settingsView(devices(3), null, 0).mics.some((slot) => slot?.selected === true)).toBe(false);
  });

  it("pages six at a time and reports the position", () => {
    const all = devices(15);
    expect(labels(settingsView(all, null, 0))[0]).toBe("Mic 0");
    expect(settingsView(all, null, 0).pageLabel).toBe("1/3");
    expect(labels(settingsView(all, null, 6))[0]).toBe("Mic 6");
    expect(settingsView(all, null, 6).pageLabel).toBe("2/3");
    // The last page is short; the unfilled keys stay empty.
    expect(labels(settingsView(all, null, 12))).toEqual(["Mic 12", "Mic 13", "Mic 14", null, null, null]);
    expect(settingsView(all, null, 12)).toMatchObject({ hasPaging: true, pageLabel: "3/3" });
  });

  // An offset outliving the list it indexed is routine: the operator pages to
  // the third screen and then unplugs an interface.
  it("wraps a stale or negative offset into range instead of blanking", () => {
    expect(labels(settingsView(devices(15), null, 90))[0]).toBe("Mic 0");
    expect(labels(settingsView(devices(15), null, -30))[0]).toBe("Mic 0");
    expect(labels(settingsView(devices(3), null, 12))[0]).toBe("Mic 0");
  });

  // Only a page boundary is a stable key mapping; mid-page offsets would put a
  // device on a different key each time the list was re-read.
  it("snaps a mid-page offset back to its page start", () => {
    expect(labels(settingsView(devices(15), null, 8))[0]).toBe("Mic 6");
  });
});

describe("nextMicPage", () => {
  it("stays at zero when everything fits on one page", () => {
    expect(nextMicPage(0, 0)).toBe(0);
    expect(nextMicPage(0, 6)).toBe(0);
  });

  it("advances a page at a time and wraps past the last", () => {
    expect(nextMicPage(0, 15)).toBe(6);
    expect(nextMicPage(6, 15)).toBe(12);
    expect(nextMicPage(12, 15)).toBe(0);
  });
});

describe("micAtSlot", () => {
  it("addresses the same device the view painted on that key", () => {
    const all = devices(15);
    for (const offset of [0, 6, 12]) {
      const view = settingsView(all, null, offset);
      for (let slot = 0; slot < MICS_PER_PAGE; slot += 1) {
        expect(micAtSlot(all, offset, slot)?.id).toBe(view.mics[slot]?.id);
      }
    }
  });

  it("returns nothing for a padded slot or a key outside the microphone block", () => {
    expect(micAtSlot(devices(2), 0, 5)).toBeUndefined();
    expect(micAtSlot(devices(9), 0, MICS_PER_PAGE)).toBeUndefined();
    expect(micAtSlot(devices(9), 0, -1)).toBeUndefined();
  });
});
