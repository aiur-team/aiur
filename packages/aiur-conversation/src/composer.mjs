/**
 * <aiur-composer>: the chat composer for apps that embed an Aiur conversation.
 *
 * Idle, it is one row: attach, the text input, mic and send. Tapping the mic
 * (or holding it) dictates into the input, and the row becomes a recording
 * row: cancel, a live waveform, two-way voice, stop and send. The element never
 * talks to Aiur or to a voice provider itself; the host hands it adapters, and
 * a button whose adapter is missing is not shown.
 */

import { BARS, TAG, TEMPLATE, iconMarkup } from './composer-view.mjs';

// A press on the mic that lasts this long is a hold, and releasing it stops
// dictation. A shorter press is a tap, and dictation runs until stop, send or cancel.
const HOLD_MS = 300;
const HTMLElementBase = globalThis.HTMLElement ?? class {};

export class AiurComposer extends HTMLElementBase {
  static get observedAttributes() {
    return ['placeholder', 'disabled', 'accept', 'pinned'];
  }

  #adapters = {};
  #attachments = [];
  #uploads = 0;
  // The dictation in progress: { session, before, after, text, end }. `end` is
  // set once the user stops, sends, cancels or switches to voice.
  #dictation = null;
  #levels = new Array(BARS).fill(0);
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
      cancel: root.querySelector('.cancel'),
      wave: root.querySelector('.wave'),
      bars: Array.from(root.querySelectorAll('.wave i')),
      mic: root.querySelector('.mic'),
      voice: root.querySelector('.voice'),
      stop: root.querySelector('.stop'),
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
    this.#endDictation('cancel');
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

  /** Sends the draft, as the send button does. While dictating, it stops dictation first. */
  async send() {
    if (this.#recording()) return this.#endDictation('send');
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
    const { input, attach, cancel, mic, voice, stop, send, file } = this.#el;

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

    this.shadowRoot.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && this.#recording()) this.#endDictation('cancel');
    });

    send.addEventListener('click', () => this.send());
    attach.addEventListener('click', () => file.click());
    file.addEventListener('change', () => {
      for (const picked of Array.from(file.files ?? [])) this.#upload(picked);
      file.value = '';
    });

    // Press starts dictation at once so no words are lost. Releasing a hold
    // stops it; releasing a tap leaves it running. The mic is hidden as soon as
    // dictation starts, so the release is caught on the window.
    mic.addEventListener('pointerdown', (event) => {
      if (event.button > 0) return;
      event.preventDefault();
      const pressedAt = Date.now();
      this.#startDictation();
      const dictation = this.#dictation;
      const win = this.ownerDocument.defaultView;
      const release = () => {
        win.removeEventListener('pointerup', release);
        win.removeEventListener('pointercancel', release);
        if (Date.now() - pressedAt >= HOLD_MS && this.#dictation === dictation) this.#endDictation('stop');
      };
      win.addEventListener('pointerup', release);
      win.addEventListener('pointercancel', release);
    });
    // A touch's click lands wherever the finger lifts, which is the stop button
    // once the row has changed; stop the touch from producing a click at all.
    mic.addEventListener('touchstart', (event) => event.preventDefault(), { passive: false });
    mic.addEventListener('contextmenu', (event) => event.preventDefault());
    // Keyboard activation (a click with no pointer behind it) starts a tap dictation.
    mic.addEventListener('click', (event) => {
      if (event.detail > 0) return;
      this.#startDictation();
      if (this.#recording()) stop.focus();
    });

    stop.addEventListener('click', () => this.#endDictation('stop'));
    cancel.addEventListener('click', () => this.#endDictation('cancel'));
    voice.addEventListener('click', () => (this.#voice ? this.#stopVoice() : this.#endDictation('voice')));
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

  #recording() {
    return Boolean(this.#dictation && !this.#dictation.end);
  }

  async #startDictation() {
    const adapter = this.#adapters.dictation;
    if (!adapter || this.#dictation || this.#voice || this.disabled) return;

    const { input } = this.#el;
    const start = input.selectionStart ?? input.value.length;
    const end = input.selectionEnd ?? input.value.length;
    const dictation = { session: null, before: input.value.slice(0, start), after: input.value.slice(end), text: '', end: null };
    this.#dictation = dictation;
    this.#level(null);
    this.#render();

    try {
      dictation.session = await adapter.start({
        onPartial: (text) => {
          if (this.#dictation === dictation && !dictation.end) this.#show(dictation, String(text ?? '').trim());
        },
        onLevel: (level) => {
          if (this.#dictation === dictation && !dictation.end) this.#level(level);
        },
      });
    } catch (error) {
      if (this.#dictation === dictation) {
        this.#show(dictation, '');
        this.#dictation = null;
        this.#render();
      }
      this.#fail('dictation', error);
      return;
    }

    // Stopped, sent or cancelled before the recorder was ready: finish now.
    if (dictation.end) await this.#settle(dictation);
  }

  /** `how` is 'stop', 'send', 'cancel' or 'voice'. */
  async #endDictation(how) {
    const dictation = this.#dictation;
    if (!dictation || dictation.end) return false;
    dictation.end = how;
    if (how === 'cancel') this.#show(dictation, '');
    this.#render();
    this.#refocus();
    if (!dictation.session) return false;
    return this.#settle(dictation);
  }

  async #settle(dictation) {
    const { session, end } = dictation;

    if (end === 'cancel') {
      this.#dictation = null;
      this.#render();
      try {
        session.cancel?.();
      } catch (error) {
        this.#fail('dictation', error);
      }
      return false;
    }

    let text = dictation.text;
    try {
      const final = await session.stop();
      if (typeof final === 'string' && final.trim()) text = final.trim();
    } catch (error) {
      this.#fail('dictation', error);
    }
    this.#show(dictation, text);
    this.#dictation = null;
    this.#render();

    if (end === 'send') return this.send();
    if (end === 'voice') return this.#startVoice();
    return false;
  }

  // Puts the dictated text between what was before and after the cursor.
  #show(dictation, text) {
    const { input } = this.#el;
    const { before, after } = dictation;
    const lead = text && before && !/\s$/.test(before) ? ' ' : '';
    const trail = text && after && !/^\s/.test(after) ? ' ' : '';
    dictation.text = text;
    input.value = before + lead + text + trail + after;
    const caret = (before + lead + text).length;
    input.setSelectionRange?.(caret, caret);
    this.#resize();
  }

  // Scrolls the waveform by one bar; `null` flattens it.
  #level(level) {
    if (level === null) this.#levels.fill(0);
    else {
      this.#levels.shift();
      this.#levels.push(Math.min(1, Math.max(0, Number(level) || 0)));
    }
    this.#el.bars.forEach((bar, index) => {
      bar.style.transform = `scaleY(${Math.max(0.1, this.#levels[index]).toFixed(2)})`;
    });
  }

  // The words dictated so far become the voice session's first turn, so they
  // leave the input rather than being sent twice. A failed start puts them back.
  async #startVoice() {
    const adapter = this.#adapters.voice;
    if (!adapter || this.#voice) return false;

    const initialText = this.value.trim();
    this.value = '';
    try {
      this.#voice = await adapter.start({
        initialText,
        onEnd: () => {
          this.#voice = null;
          this.#render();
        },
      });
    } catch (error) {
      this.value = initialText;
      this.#fail('voice', error);
    }
    this.#render();
    return Boolean(this.#voice);
  }

  async #stopVoice() {
    const session = this.#voice;
    this.#voice = null;
    this.#render();
    try {
      await session.stop();
    } catch (error) {
      this.#fail('voice', error);
    }
  }

  // A button that just hid cannot keep focus; hand it to the input.
  #refocus() {
    const active = this.shadowRoot.activeElement;
    if (active?.hidden) this.#el.input.focus();
  }

  #fail(action, error) {
    this.dispatchEvent(new CustomEvent('aiur-composer-error', { detail: { action, error }, bubbles: true, composed: true }));
  }

  get disabled() {
    return this.hasAttribute('disabled');
  }

  #canSend() {
    if (this.#recording()) return !this.#sending && !this.disabled;
    const hasContent = this.value.trim() !== '' || this.attachments.length > 0;
    return hasContent && !this.#dictation && this.#uploads === 0 && !this.#sending && !this.disabled;
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
    const { input, attach, cancel, wave, mic, voice, stop, send, attachments } = this.#el;
    const disabled = this.disabled;
    const recording = this.#recording();
    const live = Boolean(this.#voice);

    attach.hidden = recording || typeof this.#adapters.upload !== 'function';
    mic.hidden = recording || live || !this.#adapters.dictation;
    cancel.hidden = !recording;
    wave.hidden = !recording;
    stop.hidden = !recording;
    voice.hidden = !this.#adapters.voice || !(recording || live);

    attach.disabled = disabled;
    mic.disabled = disabled;
    voice.disabled = disabled;
    send.disabled = !this.#canSend();
    // Dictated words stream in, so typing meanwhile would be overwritten.
    input.readOnly = Boolean(this.#dictation);

    voice.setAttribute('aria-pressed', String(live));
    voice.setAttribute('aria-label', live ? 'End voice conversation' : 'Switch to voice conversation');
    send.setAttribute('aria-label', recording ? 'Stop and send' : 'Send');
    this.toggleAttribute('data-recording', recording);
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
      remove.innerHTML = iconMarkup('cancel');
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
