/**
 * Persisted microphone choice.
 *
 * The operator picks a microphone once and expects it to survive a sidecar
 * restart, so the selection is written to a small JSON file rather than held
 * in memory. Storage is injected as a two-function port: the audio stack does
 * not import `node:fs`, which is one of the things that keeps it liftable into
 * its own package.
 */

export interface PreferenceStore {
  read(): string | null;
  write(value: string): void;
}

export interface MicPreferences {
  /** Device id the operator chose, or null when they never chose one. */
  selectedDeviceId(): string | null;
  select(deviceId: string): void;
  /**
   * Resolves the device to actually open.
   *
   * A remembered device that is no longer attached must not leave the deck
   * capturing silence from a missing source, so the choice falls back to the
   * first available device. The stored preference is deliberately *not*
   * overwritten: unplugging a headset for an afternoon should not forget it.
   */
  resolve(available: readonly string[]): string | null;
}

export function createMicPreferences(store: PreferenceStore): MicPreferences {
  // Read through on every call rather than caching: the file is tiny, and a
  // cache would go stale against a second process editing the same path.
  const selectedDeviceId = (): string | null => {
    const value = store.read();
    return value === null || value === "" ? null : value;
  };

  return {
    selectedDeviceId,
    select(deviceId: string): void {
      store.write(deviceId);
    },
    resolve(available: readonly string[]): string | null {
      if (available.length === 0) return null;
      const chosen = selectedDeviceId();
      if (chosen !== null && available.includes(chosen)) return chosen;
      return available[0] as string;
    },
  };
}
