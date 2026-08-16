import { describe, expect, it, vi } from "vitest";
import { createMicPreferences, type PreferenceStore } from "../../src/audio/preferences.js";

/** In-memory stand-in for the JSON file the sidecar persists the choice to. */
const storeHarness = (initial: string | null): PreferenceStore & { write: ReturnType<typeof vi.fn> } => {
  let value = initial;
  const write = vi.fn((next: string) => {
    value = next;
  });
  return { read: () => value, write };
};

describe("microphone preferences", () => {
  it("reads an unset store as no selection", () => {
    expect(createMicPreferences(storeHarness(null)).selectedDeviceId()).toBeNull();
  });

  it("reads an empty string as no selection rather than an empty device id", () => {
    // A truncated or hand-edited file yields "", which must not be passed to
    // the recorder as a source name.
    expect(createMicPreferences(storeHarness("")).selectedDeviceId()).toBeNull();
  });

  it("returns a remembered device id", () => {
    expect(createMicPreferences(storeHarness("alsa_input.yeti")).selectedDeviceId()).toBe("alsa_input.yeti");
  });

  it("writes the choice through to storage so it survives a restart", () => {
    const store = storeHarness(null);
    const preferences = createMicPreferences(store);
    preferences.select("alsa_input.yeti");
    expect(store.write).toHaveBeenCalledWith("alsa_input.yeti");
    expect(preferences.selectedDeviceId()).toBe("alsa_input.yeti");
  });

  it("resolves to null when no microphone is attached", () => {
    expect(createMicPreferences(storeHarness("alsa_input.yeti")).resolve([])).toBeNull();
  });

  it("resolves to the remembered device when it is still present", () => {
    const preferences = createMicPreferences(storeHarness("alsa_input.yeti"));
    expect(preferences.resolve(["alsa_input.webcam", "alsa_input.yeti"])).toBe("alsa_input.yeti");
  });

  it("falls back to the first device without forgetting an unplugged one", () => {
    const store = storeHarness("alsa_input.yeti");
    const preferences = createMicPreferences(store);

    expect(preferences.resolve(["alsa_input.webcam"])).toBe("alsa_input.webcam");
    // Unplugging a headset for an afternoon must not erase the choice.
    expect(store.write).not.toHaveBeenCalled();
    expect(preferences.selectedDeviceId()).toBe("alsa_input.yeti");
  });

  it("falls back to the first device when nothing was ever chosen", () => {
    const store = storeHarness(null);
    const preferences = createMicPreferences(store);
    expect(preferences.resolve(["alsa_input.webcam", "alsa_input.yeti"])).toBe("alsa_input.webcam");
    expect(store.write).not.toHaveBeenCalled();
  });
});
