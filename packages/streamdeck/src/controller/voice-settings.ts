/** Voice capture and the settings surface: mic hold, Send/Cancel, microphone keys. */
import { micAtSlot, micSlotForKey, nextMicPage } from "../settings.js";
import {
  SETTINGS_TEST_MIC,
  SETTINGS_NEXT_PAGE,
  type ControllerVoice,
  type ControllerCore,
} from "./state.js";

export const createVoiceSettings = (core: ControllerCore) => {
  const { options, publish } = core;

  /** The current voice port, or null when the host wired none. */
  const voice = (): ControllerVoice | null => options.voice?.() ?? null;

  /** Ends any capture in progress without touching the buffer. */
  const stopVoice = (): void => {
    voice()?.dispose();
  };

  /**
   * Opens the settings surface and re-enumerates microphones.
   *
   * Re-enumerating here rather than on a timer is the whole discovery policy:
   * the operator plugs a headset in and then goes looking for it, so the moment
   * they open this screen is the moment the list has to be right. Polling
   * `pw-dump` in the background would spawn a process every few seconds for a
   * screen that is open for a few seconds a week.
   */
  const enterSettings = (): void => {
    stopVoice();
    const port = voice();
    port?.refresh();
    publish({ ...core.state, mode: "settings", micHeld: false, micOffset: 0, selectedMicId: port?.selectedDeviceId() ?? null });
  };

  /** True while the voice buffer holds text worth a Send key. */
  const transcriptPresent = (): boolean => voice()?.hasMessage() === true;

  /** True while the Commands dictation buffer holds text worth Approve/Cancel keys. */
  const commandDictationPresent = (): boolean => voice()?.hasMessage() === true;

  /** Stops capture and discards the buffer; used whenever the focus is dropped. */
  const leaveVoice = (): void => {
    const port = voice();
    port?.dispose();
    port?.clear();
  };

  /**
   * Delivers the settled text to the focused agent and empties the buffer.
   *
   * Guarded on `hasMessage` rather than on the key being painted: the key face
   * and the report that pressed it are a frame apart, so a press that raced the
   * buffer emptying would otherwise `say` an empty string, which the operator
   * would see land in the agent's chat as a blank turn.
   */
  const sendTranscript = (identifier: string): void => {
    const port = voice();
    if (port === null || !port.hasMessage()) return;
    options.channel()?.say(identifier, port.message());
    port.clear();
    publish({ ...core.state, hasTranscript: false });
  };

  const cancelTranscript = (): void => {
    voice()?.clear();
    publish({ ...core.state, hasTranscript: false });
  };

  const pressSettingsKey = (index: number): void => {
    const port = voice();
    const slot = micSlotForKey(index);
    if (slot !== undefined) {
      const device = port === null ? undefined : micAtSlot(port.microphones(), core.state.micOffset, slot);
      if (device === undefined) return;
      // Persisted immediately, through `MicPreferences.select`, so the choice
      // survives a sidecar restart rather than living in this closure. The id
      // is then read *back* out of the port rather than assumed, so state shows
      // what was actually stored.
      port?.select(device.id);
      publish({ ...core.state, selectedMicId: port?.selectedDeviceId() ?? null });
      return;
    }
    if (index === SETTINGS_TEST_MIC) {
      holdMic();
      return;
    }
    if (index === SETTINGS_NEXT_PAGE) {
      const count = port?.microphones().length ?? 0;
      publish({ ...core.state, micOffset: nextMicPage(core.state.micOffset, count) });
    }
  };

  /** Key-down on the mic or TestMic key: one gesture, one capture. */
  const holdMic = (): void => {
    voice()?.hold();
    publish({ ...core.state, micHeld: true });
  };

  const releaseMic = (): void => {
    if (!core.state.micHeld) return;
    voice()?.release();
    // Both buffers read the same settled text: the agent row's Send/Cancel and
    // the Commands detail view's Approve/Cancel. Whichever surface is showing
    // gets the key refresh.
    publish({ ...core.state, micHeld: false, hasTranscript: transcriptPresent(), commandDictation: commandDictationPresent() });
  };

  return {
    voice,
    stopVoice,
    leaveVoice,
    enterSettings,
    transcriptPresent,
    commandDictationPresent,
    sendTranscript,
    cancelTranscript,
    pressSettingsKey,
    holdMic,
    releaseMic,
  };
};

export type VoiceSettings = ReturnType<typeof createVoiceSettings>;
