/**
 * <aiur-composer>: the chat composer for apps that embed an Aiur conversation.
 *
 * A text input over a row of round icon buttons: attach (left), then hold to
 * dictate, two-way voice and send (right). The element never talks to Aiur or
 * to a voice provider itself; the host hands it adapters, and a button whose
 * adapter is missing is not shown.
 */

const TAG = 'aiur-composer';

const ICONS = {
  attach: '<path d="M12 5v14M5 12h14"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
  voice: '<path d="M4 10v4M8 7v10M12 4v16M16 7v10M20 10v4"/>',
  send: '<path d="M12 19V5M6 11l6-6 6 6"/>',
};

const STYLE = `
:host {
  --_bg: var(--aiur-composer-bg, var(--aiur-color-surface, #ffffff));
  --_fg: var(--aiur-composer-fg, var(--aiur-color-fg, #1c2128));
  --_muted: var(--aiur-composer-muted, var(--aiur-color-muted, #58606a));
  --_line: var(--aiur-composer-line, var(--aiur-color-line, #d0d7de));
  --_button-bg: var(--aiur-composer-button-bg, var(--aiur-color-surface-2, #eef1f4));
  --_accent: var(--aiur-composer-accent, var(--aiur-color-accent, #2457d6));
  --_on-accent: var(--aiur-composer-on-accent, #ffffff);
  --_focus: var(--aiur-composer-focus, var(--aiur-color-focus, #2457d6));
  --_radius: var(--aiur-composer-radius, var(--aiur-radius-xl, 24px));
  --_font: var(--aiur-composer-font, var(--aiur-font-body, system-ui, sans-serif));
  --_shadow: var(--aiur-composer-shadow, var(--aiur-shadow-md, 0 4px 16px rgb(0 0 0 / 0.12)));
  --_button: var(--aiur-composer-button-size, 44px);
  display: block;
  box-sizing: border-box;
  font-family: var(--_font);
  color: var(--_fg);
}
:host([hidden]) { display: none; }
:host([pinned]) {
  position: fixed;
  left: 0;
  right: 0;
  bottom: var(--aiur-composer-keyboard-inset, 0px);
  z-index: var(--aiur-composer-z, 10);
  padding: 8px max(8px, env(safe-area-inset-right)) max(8px, env(safe-area-inset-bottom)) max(8px, env(safe-area-inset-left));
}
*, *::before, *::after { box-sizing: border-box; }
.card {
  display: grid;
  gap: 8px;
  padding: 12px 12px 10px;
  background: var(--_bg);
  border: 1px solid var(--_line);
  border-radius: var(--_radius);
  box-shadow: var(--_shadow);
  min-width: 0;
}
textarea {
  display: block;
  width: 100%;
  min-height: 24px;
  max-height: var(--aiur-composer-max-input-height, 40vh);
  margin: 0;
  padding: 2px 4px;
  border: 0;
  outline: none;
  resize: none;
  overflow-y: auto;
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: max(16px, 1em);
  line-height: 1.4;
}
textarea::placeholder { color: var(--_muted); }
.attachments { display: flex; flex-wrap: wrap; gap: 6px; }
.attachments:empty { display: none; }
.chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  max-width: 100%;
  padding: 2px 4px 2px 10px;
  border: 1px solid var(--_line);
  border-radius: 999px;
  font-size: 0.85em;
}
.chip[data-state="uploading"] { color: var(--_muted); }
.chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.chip button { width: 24px; height: 24px; flex: none; }
.row { display: flex; align-items: center; gap: 8px; }
.spacer { flex: 1; }
button {
  display: inline-grid;
  place-items: center;
  width: var(--_button);
  height: var(--_button);
  padding: 0;
  border: 0;
  border-radius: 999px;
  background: var(--_button-bg);
  color: inherit;
  cursor: pointer;
  touch-action: none;
  -webkit-user-select: none;
  user-select: none;
  -webkit-touch-callout: none;
}
button[hidden] { display: none; }
button:focus-visible { outline: 2px solid var(--_focus); outline-offset: 2px; }
button:disabled { cursor: default; opacity: 0.45; }
button[aria-pressed="true"] { background: var(--_accent); color: var(--_on-accent); }
button.send { background: var(--_accent); color: var(--_on-accent); }
svg { width: 22px; height: 22px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; pointer-events: none; }
.chip svg { width: 14px; height: 14px; }
@media (prefers-reduced-motion: no-preference) {
  button[aria-pressed="true"] { animation: pulse 1.2s ease-in-out infinite; }
}
@keyframes pulse { 50% { box-shadow: 0 0 0 6px color-mix(in srgb, var(--_accent) 25%, transparent); } }
input[type="file"] { display: none; }
`;

const TEMPLATE = `
<style>${STYLE}</style>
<div class="card" part="card">
  <div class="attachments" part="attachments"></div>
  <textarea part="input" rows="1" enterkeyhint="send"></textarea>
  <div class="row" part="actions">
    <button type="button" class="attach" part="attach" aria-label="Attach files" hidden>${icon('attach')}</button>
    <span class="spacer"></span>
    <button type="button" class="mic" part="mic" aria-label="Hold to dictate" aria-pressed="false" hidden>${icon('mic')}</button>
    <button type="button" class="voice" part="voice" aria-label="Start voice conversation" aria-pressed="false" hidden>${icon('voice')}</button>
    <button type="button" class="send" part="send" aria-label="Send" disabled>${icon('send')}</button>
  </div>
  <input type="file" multiple tabindex="-1" aria-hidden="true">
</div>
`;

function icon(name) {
  return `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

const HTMLElementBase = globalThis.HTMLElement ?? class {};

export class AiurComposer extends HTMLElementBase {
  static get observedAttributes() {
    return ['placeholder', 'disabled', 'accept', 'pinned'];
  }

  #adapters = {};
  #attachments = [];
  #uploads = 0;
  #dictation = null;
  #dictationStarting = null;
  #voice = null;
  #sending = false;
  #viewportListener = null;
  #el;

  /** Called with `(text, attachments)`. A returned promise keeps the draft until it resolves. */
  onSend = null;

  constructor() {
    super();
    const root = this.attachShadow({ mode: 'open' });
    root.innerHTML = TEMPLATE;
    this.#el = {
      input: root.querySelector('textarea'),
      attachments: root.querySelector('.attachments'),
      attach: root.querySelector('.attach'),
      mic: root.querySelector('.mic'),
      voice: root.querySelector('.voice'),
      send: root.querySelector('.send'),
      file: root.querySelector('input[type="file"]'),
    };
    this.#wire();
  }

  connectedCallback() {
    this.#syncAttributes();
    if (this.hasAttribute('pinned')) this.#followKeyboard(true);
  }

  disconnectedCallback() {
    this.#followKeyboard(false);
    this.#cancelDictation();
  }

  attributeChangedCallback(name) {
    this.#syncAttributes();
    if (name === 'pinned' && this.isConnected) this.#followKeyboard(this.hasAttribute('pinned'));
  }

  /** `{ upload, dictation, voice }`; each one is optional. */
  get adapters() {
    return this.#adapters;
  }

  set adapters(value) {
    this.#adapters = value ?? {};
    this.#render();
  }

  get value() {
    return this.#el.input.value;
  }

  set value(text) {
    this.#el.input.value = text ?? '';
    this.#resize();
    this.#render();
  }

  get attachments() {
    return this.#attachments.filter((item) => item.state === 'ready').map((item) => item.attachment);
  }

  focus(options) {
    this.#el.input.focus(options);
  }

  clear() {
    this.#attachments = [];
    this.value = '';
  }

  /** Sends the draft, as the send button does. */
  async send() {
    if (!this.#canSend()) return false;
    const text = this.value.trim();
    const attachments = this.attachments;
    const detail = { text, attachments };

    this.dispatchEvent(new CustomEvent('aiur-send', { detail, bubbles: true, composed: true }));

    if (typeof this.onSend !== 'function') {
      this.clear();
      return true;
    }

    this.#sending = true;
    this.#render();
    try {
      await this.onSend(text, attachments);
      this.clear();
      return true;
    } catch (error) {
      this.#fail('send', error);
      return false;
    } finally {
      this.#sending = false;
      this.#render();
    }
  }

  #wire() {
    const { input, attach, mic, voice, send, file } = this.#el;

    input.addEventListener('input', () => {
      this.#resize();
      this.#render();
    });

    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.send();
      }
    });

    send.addEventListener('click', () => this.send());
    attach.addEventListener('click', () => file.click());
    file.addEventListener('change', () => {
      for (const picked of Array.from(file.files ?? [])) this.#upload(picked);
      file.value = '';
    });

    // Hold to dictate: press starts, release stops and inserts the text.
    mic.addEventListener('pointerdown', (event) => {
      if (event.button > 0) return;
      event.preventDefault();
      mic.setPointerCapture?.(event.pointerId);
      this.#startDictation();
    });
    mic.addEventListener('pointerup', () => this.#stopDictation());
    mic.addEventListener('pointercancel', () => this.#cancelDictation());
    mic.addEventListener('contextmenu', (event) => event.preventDefault());
    mic.addEventListener('keydown', (event) => {
      if ((event.key === ' ' || event.key === 'Enter') && !event.repeat) {
        event.preventDefault();
        this.#startDictation();
      } else if (event.key === 'Escape') {
        this.#cancelDictation();
      }
    });
    mic.addEventListener('keyup', (event) => {
      if (event.key === ' ' || event.key === 'Enter') this.#stopDictation();
    });

    voice.addEventListener('click', () => this.#toggleVoice());
  }

  async #upload(file) {
    const upload = this.#adapters.upload;
    if (typeof upload !== 'function') return;

    const item = { name: file.name, state: 'uploading', attachment: null };
    this.#attachments.push(item);
    this.#uploads += 1;
    this.#render();

    try {
      item.attachment = await upload(file);
      item.state = 'ready';
    } catch (error) {
      this.#attachments = this.#attachments.filter((other) => other !== item);
      this.#fail('upload', error);
    } finally {
      this.#uploads -= 1;
      this.#render();
    }
  }

  async #startDictation() {
    const dictation = this.#adapters.dictation;
    if (!dictation || this.#dictation || this.#dictationStarting || this.disabled) return;

    this.#el.mic.setAttribute('aria-pressed', 'true');
    const starting = Promise.resolve().then(() => dictation.start());
    this.#dictationStarting = starting;

    try {
      this.#dictation = await starting;
    } catch (error) {
      this.#el.mic.setAttribute('aria-pressed', 'false');
      this.#fail('dictation', error);
    } finally {
      this.#dictationStarting = null;
    }

    // Released before the recorder was ready: stop at once.
    if (this.#dictation && this.#el.mic.getAttribute('aria-pressed') === 'false') this.#finishDictation();
  }

  #stopDictation() {
    if (this.#el.mic.getAttribute('aria-pressed') !== 'true') return;
    this.#el.mic.setAttribute('aria-pressed', 'false');
    if (this.#dictation) this.#finishDictation();
  }

  async #finishDictation() {
    const session = this.#dictation;
    this.#dictation = null;

    try {
      const text = (await session.stop())?.trim();
      if (text) this.#insert(text);
    } catch (error) {
      this.#fail('dictation', error);
    }
  }

  #cancelDictation() {
    this.#el.mic.setAttribute('aria-pressed', 'false');
    const session = this.#dictation;
    this.#dictation = null;
    session?.cancel?.();
  }

  async #toggleVoice() {
    const voice = this.#adapters.voice;
    if (!voice) return;

    if (this.#voice) {
      const session = this.#voice;
      this.#voice = null;
      this.#render();
      try {
        await session.stop();
      } catch (error) {
        this.#fail('voice', error);
      }
      return;
    }

    try {
      this.#voice = await voice.start({
        onEnd: () => {
          this.#voice = null;
          this.#render();
        },
      });
    } catch (error) {
      this.#fail('voice', error);
    }
    this.#render();
  }

  #insert(text) {
    const { input } = this.#el;
    const start = input.selectionStart ?? input.value.length;
    const end = input.selectionEnd ?? input.value.length;
    const before = input.value.slice(0, start);
    const after = input.value.slice(end);
    const lead = before && !/\s$/.test(before) ? ' ' : '';
    const trail = after && !/^\s/.test(after) ? ' ' : '';
    input.value = before + lead + text + trail + after;
    const caret = (before + lead + text).length;
    input.setSelectionRange?.(caret, caret);
    this.#resize();
    this.#render();
  }

  #fail(action, error) {
    this.dispatchEvent(new CustomEvent('aiur-composer-error', { detail: { action, error }, bubbles: true, composed: true }));
  }

  get disabled() {
    return this.hasAttribute('disabled');
  }

  #canSend() {
    const hasContent = this.value.trim() !== '' || this.attachments.length > 0;
    return hasContent && this.#uploads === 0 && !this.#sending && !this.disabled;
  }

  #syncAttributes() {
    const { input, file } = this.#el;
    input.placeholder = this.getAttribute('placeholder') ?? '';
    input.disabled = this.disabled;
    const accept = this.getAttribute('accept');
    if (accept) file.setAttribute('accept', accept);
    else file.removeAttribute('accept');
    this.#render();
  }

  #render() {
    const { attach, mic, voice, send, attachments } = this.#el;
    const disabled = this.disabled;

    attach.hidden = typeof this.#adapters.upload !== 'function';
    mic.hidden = !this.#adapters.dictation;
    voice.hidden = !this.#adapters.voice;
    attach.disabled = disabled;
    mic.disabled = disabled;
    voice.disabled = disabled;
    send.disabled = !this.#canSend();

    const live = Boolean(this.#voice);
    voice.setAttribute('aria-pressed', String(live));
    voice.setAttribute('aria-label', live ? 'End voice conversation' : 'Start voice conversation');
    this.toggleAttribute('data-voice-live', live);

    attachments.replaceChildren(...this.#attachments.map((item) => this.#chip(item)));
  }

  #chip(item) {
    const chip = document.createElement('span');
    chip.className = 'chip';
    chip.setAttribute('part', 'attachment');
    chip.dataset.state = item.state;
    const name = document.createElement('span');
    name.textContent = item.attachment?.name ?? item.name;
    chip.append(name);

    if (item.state === 'ready') {
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.setAttribute('aria-label', `Remove ${name.textContent}`);
      remove.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>';
      remove.addEventListener('click', () => {
        this.#attachments = this.#attachments.filter((other) => other !== item);
        this.#render();
      });
      chip.append(remove);
    }

    return chip;
  }

  #resize() {
    const { input } = this.#el;
    input.style.height = 'auto';
    if (input.scrollHeight) input.style.height = `${input.scrollHeight}px`;
  }

  // A fixed element sits under an on-screen keyboard, which shrinks only the
  // visual viewport; lift the composer by the part the keyboard covers.
  #followKeyboard(on) {
    const viewport = globalThis.visualViewport;
    if (!viewport) return;

    if (this.#viewportListener) {
      viewport.removeEventListener('resize', this.#viewportListener);
      viewport.removeEventListener('scroll', this.#viewportListener);
      this.#viewportListener = null;
      this.style.removeProperty('--aiur-composer-keyboard-inset');
    }
    if (!on) return;

    this.#viewportListener = () => {
      const covered = Math.max(0, globalThis.innerHeight - viewport.height - viewport.offsetTop);
      this.style.setProperty('--aiur-composer-keyboard-inset', `${Math.round(covered)}px`);
    };
    viewport.addEventListener('resize', this.#viewportListener);
    viewport.addEventListener('scroll', this.#viewportListener);
    this.#viewportListener();
  }
}

/** Registers `<aiur-composer>` (or `tag`) once and returns the element class. */
export function defineComposer(tag = TAG, registry = globalThis.customElements) {
  if (!registry) throw new Error('defineComposer needs a browser with custom elements');
  const existing = registry.get(tag);
  if (existing) return existing;
  // Each tag needs its own class.
  const element = tag === TAG ? AiurComposer : class extends AiurComposer {};
  registry.define(tag, element);
  return element;
}
