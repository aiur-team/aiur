import type { DeckSettings } from "./deck-settings.js";

/** Follow startup settings once; only a new operator selection may redirect again. */
export function createInstanceSettings(select: (name: string, explicit: boolean) => void) {
  let first = true;
  let selectionId: string | undefined;
  return (settings: Pick<DeckSettings, "instance" | "instance_selection_id">): void => {
    const explicit = !first && settings.instance_selection_id !== undefined && settings.instance_selection_id !== selectionId;
    if ((first || explicit) && settings.instance !== null) select(settings.instance, explicit);
    first = false;
    if (settings.instance_selection_id !== undefined) selectionId = settings.instance_selection_id;
  };
}
