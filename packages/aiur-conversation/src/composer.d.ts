/** What an upload adapter returns for one file; the composer passes it back unchanged in `aiur-send`. */
export interface ComposerAttachment {
  name: string;
  [key: string]: unknown;
}

/** A dictation in progress. `stop` resolves to the final text; an empty result keeps the last partial. */
export interface DictationSession {
  stop(): Promise<string | void>;
  /** Discards the recording. The composer removes the dictated words itself. */
  cancel?(): void;
}

/** What the composer hands `dictation.start`. Call both as often as the recognizer allows. */
export interface DictationCallbacks {
  /** Everything recognized so far in this dictation (not just the new words). It replaces the previous partial in the input. */
  onPartial(text: string): void;
  /** Microphone loudness from 0 to 1. Each call scrolls the waveform by one bar. */
  onLevel(level: number): void;
}

/** A live two-way voice conversation. */
export interface VoiceSession {
  stop(): Promise<void>;
}

export interface VoiceStartOptions {
  /** Call it when the session ends by itself, such as when the agent hangs up. */
  onEnd(): void;
  /** The draft at the moment the user switched from dictation to voice; send it as the first turn. Empty if there was none. */
  initialText: string;
}

export interface ComposerAdapters {
  /** Uploads one file. Without it the attach button is not shown. */
  upload?: (file: File) => Promise<ComposerAttachment>;
  /** Starts recording when the mic is tapped or pressed. Without it the mic button is not shown. */
  dictation?: { start(callbacks: DictationCallbacks): Promise<DictationSession> };
  /** Starts a live voice conversation from the recording row. Without it the two-way voice button is not shown. */
  voice?: { start(options: VoiceStartOptions): Promise<VoiceSession> };
}

export interface ComposerSendDetail {
  text: string;
  attachments: ComposerAttachment[];
}

export interface ComposerErrorDetail {
  action: 'send' | 'upload' | 'dictation' | 'voice';
  error: unknown;
}

export declare class AiurComposer extends HTMLElement {
  adapters: ComposerAdapters;
  /** Called on send. A returned promise keeps the draft until it resolves; a rejection keeps it and fires `aiur-composer-error`. */
  onSend: ((text: string, attachments: ComposerAttachment[]) => unknown) | null;
  value: string;
  readonly attachments: ComposerAttachment[];
  readonly disabled: boolean;
  /** Sends the draft. While dictating, it stops dictation and sends the final words. */
  send(): Promise<boolean>;
  clear(): void;
}

/** Registers `<aiur-composer>` (or `tag`) once and returns the element class. */
export declare function defineComposer(tag?: string, registry?: CustomElementRegistry): typeof AiurComposer;

declare global {
  interface HTMLElementTagNameMap {
    'aiur-composer': AiurComposer;
  }
  interface HTMLElementEventMap {
    'aiur-send': CustomEvent<ComposerSendDetail>;
    'aiur-composer-error': CustomEvent<ComposerErrorDetail>;
  }
}
