/** What an upload adapter returns for one file; the composer passes it back unchanged in `aiur-send`. */
export interface ComposerAttachment {
  name: string;
  [key: string]: unknown;
}

/** A dictation in progress. `stop` resolves to the transcribed text. */
export interface DictationSession {
  stop(): Promise<string>;
  cancel?(): void;
}

/** A live two-way voice conversation. */
export interface VoiceSession {
  stop(): Promise<void>;
}

export interface ComposerAdapters {
  /** Uploads one file. Without it the attach button is not shown. */
  upload?: (file: File) => Promise<ComposerAttachment>;
  /** Starts recording on press; the composer calls `stop` on release. Without it the mic button is not shown. */
  dictation?: { start(): Promise<DictationSession> };
  /** Starts a live voice conversation; call `onEnd` if it ends on its own. Without it the voice button is not shown. */
  voice?: { start(options: { onEnd(): void }): Promise<VoiceSession> };
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
