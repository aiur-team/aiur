import { conversationError } from './conversation-error.mjs';

/** Headless ticket thread state and transport lifecycle. */
export class ThreadController extends EventTarget {
  #state = { entries: [], cursor: null, loading: false, sending: false, receipt: null, error: null };
  #adapters;
  #unsubscribe = null;
  #loadPromise = null;
  #requestId = null;
  #receiptGeneration = 0;
  #answered = new Set();

  constructor(adapters = {}) {
    super();
    this.#adapters = adapters;
  }

  get state() { return structuredClone(this.#state); }

  async load() {
    if (this.#loadPromise) return this.#loadPromise;
    const generation = this.#generation;
    this.#loadPromise = this.#load(generation);
    try { return await this.#loadPromise; } finally { this.#loadPromise = null; }
  }

  async #load(generation) {
    this.#patch({ loading: true, error: null });
    try {
      const result = await this.#adapters.read({ after: this.#state.cursor, limit: 100 });
      if (generation !== this.#generation) return false;
      const entries = [...this.#state.entries];
      const known = new Set(entries.map((entry) => entry.pos));
      for (const entry of result.entries ?? []) if (!known.has(entry.pos)) entries.push(entry);
      this.#patch({ entries, cursor: result.next_after ?? result.cursor ?? this.#state.cursor, headPos: result.head_pos ?? this.#state.headPos ?? null });
      return true;
    } catch (error) {
      if (generation !== this.#generation) return false;
      this.#patch({ error: conversationError('read', error) });
      return false;
    } finally { if (generation === this.#generation) this.#patch({ loading: false }); }
  }

  connect() {
    this.#unsubscribe?.();
    this.#unsubscribe = this.#adapters.subscribe?.(() => this.load()) ?? null;
    return () => { this.#unsubscribe?.(); this.#unsubscribe = null; };
  }

  #generation = 0;

  set adapters(adapters) {
    this.#generation++;
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    this.#adapters = adapters;
  }

  get adapters() { return this.#adapters; }

  async send(text, attachments = []) {
    const message = String(text ?? '').trim();
    if (!message && attachments.length === 0) return false;
    this.#receiptGeneration++;
    this.#patch({ sending: true, error: null });
    try {
      const messageId = crypto.randomUUID();
      const result = await this.#adapters.send({ message_id: messageId, text: message, attachments });
      this.#requestId = result?.request_id ?? result?.receipt?.request_id ?? null;
      this.#patch({ receipt: result?.receipt ?? result ?? null });
      await this.load();
      return true;
    } catch (error) {
      this.#patch({ error: conversationError('send', error) });
      return false;
    } finally { this.#patch({ sending: false }); }
  }

  async refreshReceipt() {
    const requestId = this.#requestId ?? this.#state.receipt?.request_id ?? this.#state.receipt?.id;
    if (requestId == null || !this.#adapters.receipt) return this.#state.receipt;
    const generation = this.#receiptGeneration;
    try {
      const receipt = await this.#adapters.receipt(String(requestId));
      const normalized = { ...receipt, request_id: String(requestId) };
      if (generation === this.#receiptGeneration) this.#patch({ receipt: normalized });
      return normalized;
    } catch (error) {
      this.#patch({ error: conversationError('read', error) });
      return null;
    }
  }

  answer(commandId, answer) {
    return Promise.resolve().then(() => this.#adapters.answer({ command_id: commandId, answer })).then((result) => {
      this.#answered.add(commandId);
      const entries = result?.entry ? [...this.#state.entries, result.entry] : this.#state.entries;
      this.#patch({ entries, answeredCommands: [...this.#answered] });
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
