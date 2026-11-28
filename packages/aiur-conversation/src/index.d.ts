export * from './composer.js';
export type ThreadEntry = { pos: number; role?: string; kind?: string; text?: string; at?: string; decision_id?: string; media?: Array<{ url: string; name?: string; mime_type?: string }> };
export type ThreadReceipt = { request_id?: string | number; id?: string | number; status?: string; mode?: string };
export declare class ThreadController extends EventTarget {
  constructor(adapters: {
    read(options: { after: number | null; limit: number }): Promise<{ entries: ThreadEntry[]; next_after?: number; head_pos?: number }>;
    send(message: { message_id: string; text: string; attachments: unknown[] }): Promise<unknown>;
    receipt?(requestId: string): Promise<unknown>;
    answer?(command: { command_id: string; answer: string }): Promise<unknown>;
    subscribe?(onChanged: () => void): (() => void) | void;
  });
  adapters: ConstructorParameters<typeof ThreadController>[0];
  readonly state: { entries: ThreadEntry[]; cursor: number | null; headPos?: number; loading: boolean; sending: boolean; receipt: ThreadReceipt | null; answeredCommands?: string[]; error: unknown };
  load(): Promise<boolean>;
  connect(): () => void;
  send(text: string, attachments?: unknown[]): Promise<boolean>;
  refreshReceipt(): Promise<unknown>;
  answer(commandId: string, answer: string): Promise<boolean>;
}
export declare class AiurThread extends HTMLElement {
  adapters: ConstructorParameters<typeof ThreadController>[0];
  readonly state: ThreadController['state'];
  load(): Promise<boolean>;
  send(text: string, attachments?: unknown[]): Promise<boolean>;
  refreshReceipt(): Promise<unknown>;
  answer(commandId: string, answer: string): Promise<boolean>;
}
export declare function defineThread(tag?: string, registry?: CustomElementRegistry): typeof AiurThread;
