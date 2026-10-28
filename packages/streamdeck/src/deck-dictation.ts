import { createChunkAggregator } from "./audio/aggregate.js";
import { createTranscriptBuffer } from "./audio/buffer.js";
import { createRelayTranscriber } from "./audio/relay.js";
import type { Capture, CaptureHandlers } from "./audio/capture.js";
import type { TranscriberSession } from "./audio/stt.js";
import type { RawInput } from "./frame-input.js";
import { createVoiceLink } from "./voiceHost.js";
import type { StreamDeckVoiceState } from "./channel-types.js";

interface DictationChannel {
  voiceStart(): void;
  voiceAudio(session: string, audio: string): void;
  voiceStop(session: string): void;
  say(identifier: string, text: string): void;
  voiceStatus(text: string): void;
}

/** Dial 3 holds to dictate; a later tap sends only settled text to its ticket. */
export function createDeckDictation(options: {
  channel(): DictationChannel | null;
  capture(handlers: CaptureHandlers): Capture;
  setTimer(fn: () => void, ms: number): unknown;
  clearTimer(handle: unknown): void;
}) {
  let focused: string | null = null;
  let availability: StreamDeckVoiceState = { available: false, reason: "Voice availability unknown" };
  let timer: unknown = null;
  let held = false;
  let recording: Capture | null = null;
  let transcription: TranscriberSession | null = null;
  let sessionId: string | null = null;
  let commitPending = false;
  let pendingStart = false;
  const buffer = createTranscriptBuffer();
  const status = (text: string): void => {
    let clipped = "";
    for (const character of text) {
      if (Buffer.byteLength(clipped + character, "utf8") > 200) break;
      clipped += character;
    }
    options.channel()?.voiceStatus(clipped);
  };
  const link = createVoiceLink({ channel: options.channel, relay: () => relay });
  const relay = createRelayTranscriber({ port: link.port });
  const chunks = createChunkAggregator((pcm) => transcription?.push(pcm));
  const cancelTimer = (): void => { if (timer !== null) options.clearTimer(timer); timer = null; };
  const reset = (): void => {
    cancelTimer();
    recording?.stop(); recording = null;
    transcription?.close(); transcription = null;
    link.drop("Dictation focus changed");
    sessionId = null; commitPending = false; held = false;
    buffer.clear(); chunks.reset();
  };
  const release = (): void => {
    recording?.stop(); recording = null;
    chunks.flush();
    // Keep the relay open until voice_closed so the provider's committed tail
    // can still settle after the physical release.
    if (sessionId !== null) options.channel()?.voiceStop(sessionId);
    else commitPending = true;
    status("Settling dictation; tap dial 3 to send");
  };
  return {
    focus(identifier: string | null): void { if (focused !== identifier) { reset(); focused = identifier; } },
    disconnect(): void { reset(); focused = null; },
    availability(value: StreamDeckVoiceState): void { availability = value; },
    input(event: RawInput): void {
      if (event.kind !== "dial" || event.index !== 2) return;
      if (event.action === "down") {
        cancelTimer();
        timer = options.setTimer(() => {
          timer = null;
          held = true;
          if (focused === null) { status("Open a ticket before dictating"); return; }
          if (!availability.available) { status(availability.reason ?? "Voice unavailable"); return; }
          if (pendingStart) { status("Waiting for the previous voice session"); return; }
          transcription?.close();
          buffer.clear(); chunks.reset(); sessionId = null; commitPending = false;
          pendingStart = true;
          transcription = relay.transcriber.open({ onTranscript: (value) => buffer.apply(value), onError: (reason) => { recording?.stop(); recording = null; status(reason); } });
          recording = options.capture({ onChunk: chunks.push, onError: (reason) => { release(); status(reason); } });
          status("Listening; release dial 3 to finish");
        }, 500);
      } else if (event.action === "up") {
        cancelTimer();
        if (recording !== null) release();
      } else if (event.action === "press") {
        if (held) { held = false; return; }
        if (focused !== null && buffer.committed().trim() !== "") {
          options.channel()?.say(focused, buffer.committed());
          buffer.clear(); status("Dictation sent");
        }
      } else if (event.action === "long_press") held = false;
    },
    started(id: string | null, reason: string | null): void {
      pendingStart = false;
      if (transcription === null) { if (id !== null) options.channel()?.voiceStop(id); return; }
      sessionId = id;
      link.started(id, reason);
      if (id !== null && commitPending) { options.channel()?.voiceStop(id); commitPending = false; }
    },
    voice(id: string, kind: "partial" | "final", text: string): void {
      link.transcript(id, { kind, text });
      if (id === sessionId && kind === "final") status("Dictation ready; tap dial 3 to send");
    },
    error(id: string, reason: string): void { link.failed(id, reason); },
    closed(id: string): void { link.closed(id); if (id === sessionId) { recording?.stop(); recording = null; sessionId = null; transcription = null; } },
  };
}
