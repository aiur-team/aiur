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

export type ConversationAction = 'send' | 'upload' | 'dictation' | 'voice';
export type ConversationErrorCode = 'permission_denied' | 'upload_failed' | 'provider_unavailable' | 'send_failed';

export interface ComposerErrorDetail {
  action: ConversationAction;
  code: ConversationErrorCode;
  message: string;
  error: unknown;
}

export declare function conversationError(action: ConversationAction, error: unknown): ComposerErrorDetail;

export interface ComposerControlState {
  label: string;
  hidden: boolean;
  disabled: boolean;
}

export interface ComposerState {
  value: string;
  disabled: boolean;
  caret: number | null;
  dictation: 'idle' | 'recording' | 'stopping';
  voice: 'idle' | 'starting' | 'live' | 'stopping';
  sending: boolean;
  readOnly: boolean;
  attachments: { id: number; name: string; state: 'uploading' | 'ready' }[];
  levels: number[];
  error: ComposerErrorDetail | null;
  announcement: string;
  inputLabel: string;
  focusOrder: string[];
  controls: Record<'attach' | 'mic' | 'cancel' | 'stop' | 'send', ComposerControlState>
    & { voice: ComposerControlState & { pressed: boolean } };
}

interface ComposerEvents {
  'aiur-send': ComposerSendDetail;
  'aiur-conversation-state': ComposerState;
  'aiur-conversation-error': ComposerErrorDetail;
}

interface ComposerCommands {
  adapters: ComposerAdapters;
  /** A rejection keeps the draft and publishes a conversation error. */
  onSend: ((text: string, attachments: ComposerAttachment[]) => unknown) | null;
  value: string;
  readonly attachments: ComposerAttachment[];
  readonly state: ComposerState;
  readonly disabled: boolean;
  send(): Promise<boolean>;
  clear(): void;
  attach(file: File): Promise<boolean>;
  removeAttachment(id: number): void;
  startDictation(start?: number, end?: number): Promise<void>;
  stopDictation(): Promise<boolean>;
  cancelDictation(): Promise<boolean>;
  startVoice(): Promise<boolean>;
  stopVoice(): Promise<void>;
}

export interface ComposerController extends ComposerCommands {
  disabled: boolean;
}

export declare class ComposerController extends EventTarget {
  addEventListener<K extends keyof ComposerEvents>(
    type: K, listener: (event: Event & { detail: ComposerEvents[K] }) => void,
    options?: boolean | AddEventListenerOptions,
  ): void;
  addEventListener(type: string, listener: EventListenerOrEventListenerObject | null, options?: boolean | AddEventListenerOptions): void;
}

export interface AiurComposer extends ComposerCommands {}

export declare class AiurComposer extends HTMLElement {
  /** Defaults to the current input selection. */
  startDictation(start?: number, end?: number): Promise<void>;
  openFilePicker(): void;
}

/** Registers `<aiur-composer>` (or `tag`) once and returns the element class. */
export declare function defineComposer(tag?: string, registry?: CustomElementRegistry): typeof AiurComposer;

declare global {
  interface HTMLElementTagNameMap {
    'aiur-composer': AiurComposer;
  }
  interface HTMLElementEventMap {
    'aiur-send': CustomEvent<ComposerSendDetail>;
    'aiur-conversation-state': CustomEvent<ComposerState>;
    'aiur-conversation-error': CustomEvent<ComposerErrorDetail>;
    'aiur-composer-error': CustomEvent<ComposerErrorDetail>;
  }
}
