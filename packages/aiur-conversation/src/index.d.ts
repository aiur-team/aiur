export * from './composer.js';
export declare class ThreadController extends EventTarget {
  constructor(adapters: {
    read(options: { after: string | null }): Promise<{ entries: unknown[]; cursor?: string }>;
    send(message: { message_id: string; text: string; attachments: unknown[] }): Promise<unknown>;
    receipt?(requestId: string): Promise<unknown>;
    answer?(command: { command_id: string; answer: string }): Promise<unknown>;
    subscribe?(onChanged: () => void): (() => void) | void;
  });
  readonly state: { entries: unknown[]; cursor: string | null; loading: boolean; sending: boolean; receipt: unknown; error: unknown };
  load(): Promise<boolean>;
  send(text: string, attachments?: unknown[]): Promise<boolean>;
  refreshReceipt(): Promise<unknown>;
  answer(commandId: string, answer: string): Promise<unknown>;
}
export declare class AiurThread extends HTMLElement {
  adapters: ConstructorParameters<typeof ThreadController>[0];
  readonly state: ThreadController['state'];
  load(): Promise<boolean>;
  send(text: string, attachments?: unknown[]): Promise<boolean>;
  refreshReceipt(): Promise<unknown>;
  answer(commandId: string, answer: string): Promise<unknown>;
}
export declare function defineThread(tag?: string, registry?: CustomElementRegistry): typeof AiurThread;
