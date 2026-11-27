/** Headless ticket thread state and transport lifecycle. */
export class ThreadController extends EventTarget {
  #state = { entries: [], cursor: null, loading: false, sending: false, error: null };
  #adapters;

  constructor(adapters = {}) {
    super();
    this.#adapters = adapters;
  }

  get state() { return structuredClone(this.#state); }

  async load() {
    this.#patch({ loading: true, error: null });
    try {
      const result = await this.#adapters.read({ after: this.#state.cursor });
      this.#patch({ entries: [...this.#state.entries, ...result.entries], cursor: result.cursor ?? this.#state.cursor });
      return true;
    } catch (error) {
      this.#patch({ error: this.#error('read', error) });
      return false;
    } finally { this.#patch({ loading: false }); }
  }

  async send(text, attachments = []) {
    const message = String(text ?? '').trim();
    if (!message && attachments.length === 0) return false;
    this.#patch({ sending: true, error: null });
    try {
      await this.#adapters.send({ message_id: crypto.randomUUID(), text: message, attachments });
      await this.load();
      return true;
    } catch (error) {
      this.#patch({ error: this.#error('send', error) });
      return false;
    } finally { this.#patch({ sending: false }); }
  }

  answer(commandId, answer) {
    return this.#adapters.answer({ command_id: commandId, answer });
  }

  #error(action, error) {
    return { action, code: error?.code ?? (action === 'send' ? 'send_failed' : 'provider_unavailable'), message: error?.message ?? String(error), error };
  }

  #patch(patch) {
    this.#state = { ...this.#state, ...patch };
    this.dispatchEvent(new CustomEvent('aiur-conversation-state', { detail: this.state }));
    if (this.#state.error) this.dispatchEvent(new CustomEvent('aiur-conversation-error', { detail: this.#state.error }));
  }
}
