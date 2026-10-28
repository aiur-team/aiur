import type { AudioDevice } from "./audio/devices.js";

export interface DeckSettings {
  readonly mic_id: string | null;
  readonly speaker_id: string | null;
  readonly default_view: "ticket" | "feature" | "epic" | "fleet";
  readonly default_sort: string;
  readonly brightness: number | null;
  readonly dim_after_seconds: number;
  readonly instance: string | null;
  readonly alerts: Readonly<Record<string, { readonly flash: boolean; readonly chime: boolean }>>;
}

export interface DeckDevices {
  readonly mics: readonly AudioDevice[];
  readonly speakers: readonly AudioDevice[];
  readonly instances: readonly string[];
  readonly legacy_mic_id?: string;
}

/** Keep the saved id intact while an unplugged device falls back locally. */
export const resolveAudioDevice = (saved: string | null, devices: readonly AudioDevice[]): string | null =>
  devices.find((device) => device.id === saved)?.id ?? devices[0]?.id ?? null;

/** Runtime brightness/idle state; timer and hardware writes belong to the host. */
export function createDeckBrightness(options: {
  defaultBrightness: number;
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
  write(brightness: number): void;
}) {
  let brightness = options.defaultBrightness;
  let dimAfter = 0;
  let timer: unknown = null;
  let dimmed = false;
  let flashTimer: unknown = null;
  const cancelFlash = (): void => {
    if (flashTimer !== null) options.clearTimer(flashTimer);
    flashTimer = null;
  };
  const cancel = (): void => {
    if (timer !== null) options.clearTimer(timer);
    timer = null;
  };
  const schedule = (): void => {
    cancel();
    if (dimAfter > 0) timer = options.setTimer(() => {
      timer = null;
      dimmed = true;
      cancelFlash();
      options.write(0);
    }, dimAfter * 1000);
  };
  return {
    apply(settings: Pick<DeckSettings, "brightness" | "dim_after_seconds">): void {
      cancelFlash();
      brightness = Math.round(Math.min(100, Math.max(0, settings.brightness ?? options.defaultBrightness)));
      dimAfter = Math.max(0, settings.dim_after_seconds);
      dimmed = false;
      options.write(brightness);
      schedule();
    },
    opened(): void { cancelFlash(); dimmed = false; options.write(brightness); schedule(); },
    input(): void { if (flashTimer !== null) options.write(dimmed ? 0 : brightness); cancelFlash(); if (dimmed) { dimmed = false; options.write(brightness); } schedule(); },
    flash(): void {
      cancelFlash();
      options.write(!dimmed && brightness === 100 ? 0 : 100);
      flashTimer = options.setTimer(() => { flashTimer = null; options.write(dimmed ? 0 : brightness); }, 200);
    },
    stop(): void { cancel(); cancelFlash(); },
  };
}
