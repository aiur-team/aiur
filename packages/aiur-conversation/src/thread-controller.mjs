import { conversationError } from './conversation-error.mjs';

/** Headless ticket thread state and transport lifecycle. */
export class ThreadController extends EventTarget {
  #state = { entries: [], cursor: null, loading: false, sending: false, receipt: null, error: null };
  #adapters;
  #unsubscribe = null;

  constructor(adapters = {}) {
    super();
    this.#adapters = adapters;
  }

  get state() { return structuredClone(this.#state); }

  async load() {
    this.#patch({ loading: true, error: null });
    try {
      const result = await this.#adapters.read({ after: this.#state.cursor, limit: 100 });
      const entries = [...this.#state.entries];
      const known = new Set(entries.map((entry) => entry.pos));
      for (const entry of result.entries ?? []) if (!known.has(entry.pos)) entries.push(entry);
      this.#patch({ entries, cursor: result.next_after ?? result.cursor ?? this.#state.cursor });
      return true;
    } catch (error) {
      this.#patch({ error: conversationError('read', error) });
      return false;
    } finally { this.#patch({ loading: false }); }
  }

  connect() {
    this.#unsubscribe?.();
    this.#unsubscribe = this.#adapters.subscribe?.(() => this.load()) ?? null;
    return () => { this.#unsubscribe?.(); this.#unsubscribe = null; };
  }

  async send(text, attachments = []) {
    const message = String(text ?? '').trim();
    if (!message && attachments.length === 0) return false;
    this.#patch({ sending: true, error: null });
    try {
      const result = await this.#adapters.send({ message_id: crypto.randomUUID(), text: message, attachments });
      this.#patch({ receipt: result?.receipt ?? result ?? null });
      await this.load();
      return true;
    } catch (error) {
      this.#patch({ error: conversationError('send', error) });
      return false;
    } finally { this.#patch({ sending: false }); }
  }

  async refreshReceipt() {
    const requestId = this.#state.receipt?.request_id;
    if (requestId == null || !this.#adapters.receipt) return this.#state.receipt;
    try {
      const receipt = await this.#adapters.receipt(String(requestId));
      this.#patch({ receipt });
      return receipt;
    } catch (error) {
      this.#patch({ error: conversationError('read', error) });
      return null;
    }
  }

  answer(commandId, answer) {
    return Promise.resolve().then(() => this.#adapters.answer({ command_id: commandId, answer })).then((result) => {
      if (result?.entry) this.#patch({ entries: [...this.#state.entries, result.entry] });
      return true;
    }).catch((error) => {
      this.#patch({ error: conversationError('answer', error) });
      return false;
    });
  }

  #patch(patch) {
    this.#state = { ...this.#state, ...patch };
    this.dispatchEvent(new CustomEvent('aiur-conversation-state', { detail: this.state }));
    if (this.#state.error) this.dispatchEvent(new CustomEvent('aiur-conversation-error', { detail: this.#state.error }));
  }
}
