/** Deck-local effects only; alert delivery remains the daemon's responsibility. */
export type AlertKind = "command" | "ci_red" | "error" | "usage_limited";
export type AlertChoices = Readonly<Partial<Record<AlertKind, { readonly flash: boolean; readonly chime: boolean }>>>;

export function deckAlertKind(event: Readonly<Record<string, unknown>>): AlertKind | null {
  const name = typeof event.name === "string" ? event.name : "";
  if (name === "command" || name.endsWith(".command") || name.includes("decision.requested")) return "command";
  if (name === "ci_red" || name.endsWith(".ci.failed")) return "ci_red";
  if (name === "usage_limited" || name.endsWith(".usage_limited")) return "usage_limited";
  if (name === "error" || event.severity === "error" || event.severity === "critical") return "error";
  return null;
}

export function createDeckAlerts(options: {
  choices(): AlertChoices;
  flash(): void;
  chime(): void;
}) {
  return (event: Readonly<Record<string, unknown>>): void => {
    const kind = deckAlertKind(event);
    if (kind === null) return;
    const choice = options.choices()[kind];
    if (choice?.flash) options.flash();
    if (choice?.chime) options.chime();
  };
}

/** Short 660 Hz PCM chime for the existing mono 44.1 kHz pacat port. */
export function deckChime(): Uint8Array {
  const samples = 4410;
  const bytes = new Uint8Array(samples * 2);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < samples; index++) {
    const envelope = Math.min(index / 220, (samples - index) / 440, 1);
    view.setInt16(index * 2, Math.round(Math.sin(index * 2 * Math.PI * 660 / 44100) * 5000 * envelope), true);
  }
  return bytes;
}
