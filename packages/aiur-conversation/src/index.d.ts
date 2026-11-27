export * from './composer.js';
export declare class ThreadController extends EventTarget {
  constructor(adapters: {
    read(options: { after: string | null }): Promise<{ entries: unknown[]; cursor?: string }>;
    send(message: { message_id: string; text: string; attachments: unknown[] }): Promise<unknown>;
    answer?(command: { command_id: string; answer: string }): Promise<unknown>;
  });
  readonly state: { entries: unknown[]; cursor: string | null; loading: boolean; sending: boolean; error: unknown };
  load(): Promise<boolean>;
  send(text: string, attachments?: unknown[]): Promise<boolean>;
  answer(commandId: string, answer: string): Promise<unknown>;
}
