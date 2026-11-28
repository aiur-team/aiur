import { ThreadController } from './thread-controller.mjs';

const BASE = globalThis.HTMLElement ?? class {};
const STYLE = `:host{display:block;color:var(--aiur-thread-fg,var(--aiur-color-fg,#1c2128));font:var(--aiur-thread-font,var(--aiur-font-body,system-ui,sans-serif))}*{box-sizing:border-box}.thread{display:flex;flex-direction:column;gap:var(--aiur-thread-gap,12px);padding:var(--aiur-thread-padding,12px);background:var(--aiur-thread-bg,var(--aiur-color-surface,#fff));border:1px solid var(--aiur-thread-line,var(--aiur-color-line,#d0d7de));border-radius:var(--aiur-thread-radius,12px);max-height:var(--aiur-thread-max-height,60vh);overflow:auto}.entries{display:flex;flex-direction:column;gap:8px}.entry{align-self:start;max-width:85%;padding:8px 12px;border-radius:var(--aiur-thread-entry-radius,12px);background:var(--aiur-thread-entry-bg,var(--aiur-color-surface-2,#eef1f4));white-space:pre-wrap;overflow-wrap:anywhere}.entry[data-role="operator"]{align-self:end;background:var(--aiur-thread-own-bg,var(--aiur-color-accent,#dcecff))}.entry time{display:block;color:var(--aiur-thread-muted,var(--aiur-color-muted,#58606a));font-size:.8em}.error{color:var(--aiur-thread-error,#b42318)}button,textarea{font:inherit;color:inherit;background:var(--aiur-thread-control-bg,var(--aiur-color-surface-2,#eef1f4));border:1px solid var(--aiur-thread-line,#d0d7de);border-radius:6px;padding:6px 10px}button:focus-visible,textarea:focus-visible{outline:2px solid var(--aiur-thread-focus,var(--aiur-color-focus,Highlight))}[hidden]{display:none!important}`;

export class AiurThread extends BASE {
  #controller = new ThreadController();
  #root;
  #entries;
  #status;
  #unsubscribe;
  #adapters = {};

  constructor() {
    super();
    this.#root = this.attachShadow({ mode: 'open' });
    this.#root.innerHTML = `<style>${STYLE}</style><section class="thread" part="thread" aria-label="Ticket conversation"><div class="entries" part="entries"></div><p class="status" part="status" role="status"></p><p class="error" part="error" role="alert" hidden></p><slot name="controls"></slot><slot name="entry"></slot></section>`;
    this.#entries = this.#root.querySelector('.entries');
    this.#status = this.#root.querySelector('.status');
    this.#wireController();
  }

  set adapters(value) { this.#adapters = value ?? {}; this.#unsubscribe?.(); this.#controller = new ThreadController(this.#adapters); this.#wireController(); if (this.isConnected) { this.#unsubscribe = this.#controller.connect(); this.load(); } }
  get adapters() { return this.#adapters; }
  get state() { return this.#controller.state; }
  load() { return this.#controller.load(); }
  send(text, attachments) { return this.#controller.send(text, attachments); }
  refreshReceipt() { return this.#controller.refreshReceipt(); }
  answer(commandId, answer) { return this.#controller.answer(commandId, answer); }

  connectedCallback() { this.#unsubscribe = this.#controller.connect(); this.load(); }
  disconnectedCallback() { this.#unsubscribe?.(); }

  #wireController() {
    for (const type of ['aiur-conversation-state', 'aiur-conversation-error']) {
      this.#controller.addEventListener(type, ({ detail }) => {
        if (type === 'aiur-conversation-state') this.#render(detail);
        this.dispatchEvent(new CustomEvent(type, { detail, bubbles: true, composed: true }));
      });
    }
  }

  #render(state) {
    this.#status.textContent = state.loading ? 'Loading conversation…' : state.entries.length ? '' : 'No messages yet';
    const error = this.#root.querySelector('.error');
    error.hidden = !state.error;
    error.textContent = state.error?.message ?? '';
    this.#entries.replaceChildren(...state.entries.map((entry) => {
      const article = this.ownerDocument.createElement('article');
      article.className = 'entry'; article.setAttribute('part', 'entry'); article.dataset.role = entry.role ?? '';
      article.dataset.kind = entry.kind ?? '';
      const body = this.ownerDocument.createElement('div'); body.setAttribute('part', 'entry-body'); body.textContent = entry.text ?? entry.body ?? (entry.kind === 'command' ? `Command ${entry.decision_id ?? ''}` : '');
      article.append(body);
      for (const media of entry.media ?? entry.attachments ?? []) {
        if (!media?.url) continue;
        let url;
        try { url = new URL(media.url, this.ownerDocument.baseURI); } catch { continue; }
        if (!['http:', 'https:', 'blob:'].includes(url.protocol)) continue;
        let visual;
        if (media.mime_type?.startsWith('image/')) {
          visual = this.ownerDocument.createElement('img'); visual.alt = media.name ?? 'Conversation attachment'; visual.src = url.href;
        } else if (media.mime_type?.startsWith('audio/')) {
          visual = this.ownerDocument.createElement('audio'); visual.controls = true; visual.src = url.href;
        } else if (media.mime_type?.startsWith('video/')) {
          visual = this.ownerDocument.createElement('video'); visual.controls = true; visual.src = url.href;
        } else {
          visual = this.ownerDocument.createElement('a'); visual.href = url.href; visual.rel = 'noopener'; visual.textContent = media.name ?? 'Open attachment';
        }
        visual.setAttribute('part', 'media'); article.append(visual);
      }
      if (entry.kind === 'command' && entry.decision_id) {
        const form = this.ownerDocument.createElement('form'); form.setAttribute('part', 'verdict');
        const label = this.ownerDocument.createElement('label'); label.setAttribute('part', 'verdict-label'); label.textContent = 'Your answer';
        const input = this.ownerDocument.createElement('textarea'); input.required = true; input.setAttribute('part', 'verdict-input');
        const submit = this.ownerDocument.createElement('button'); submit.type = 'submit'; submit.setAttribute('part', 'verdict-submit'); submit.textContent = 'Answer';
        form.addEventListener('submit', async (event) => {
          event.preventDefault(); submit.disabled = true;
          const sent = await this.answer(entry.decision_id, input.value);
          if (sent) form.remove(); else submit.disabled = false;
        });
        label.append(input); form.append(label, submit); article.append(form);
      }
      if (entry.at) { const time = this.ownerDocument.createElement('time'); time.setAttribute('part', 'timestamp'); time.dateTime = entry.at; time.textContent = new Date(entry.at).toLocaleString(); article.append(time); }
      return article;
    }));
    this.setAttribute('data-loading', String(state.loading));
    if (state.error) this.setAttribute('data-error-code', state.error.code ?? 'unknown'); else this.removeAttribute('data-error-code');
    this.dispatchEvent(new CustomEvent('aiur-thread-state', { detail: state, bubbles: true, composed: true }));
  }
}

export function defineThread(tag = 'aiur-thread', registry = globalThis.customElements) {
  if (!registry) throw new Error('defineThread needs a browser with custom elements');
  const existing = registry.get(tag);
  if (existing) return existing;
  const element = tag === 'aiur-thread' ? AiurThread : class extends AiurThread {};
  registry.define(tag, element);
  return element;
}
