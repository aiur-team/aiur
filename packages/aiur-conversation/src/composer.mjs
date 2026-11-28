import { ComposerController } from './composer-controller.mjs';
import { TAG, TEMPLATE, iconMarkup } from './composer-view.mjs';

export { ComposerController };
export { conversationError } from './conversation-error.mjs';

// A shorter press leaves dictation running until stop, send or cancel.
const HOLD_MS = 300;
const HTMLElementBase = globalThis.HTMLElement ?? class {};

export class AiurComposer extends HTMLElementBase {
  static get observedAttributes() {
    return ['placeholder', 'disabled', 'accept', 'pinned'];
  }

  #controller = new ComposerController();
  #viewportListener = null;
  #release = null;
  #el;

  constructor() {
    super();
    const root = this.attachShadow({ mode: 'open' });
    root.innerHTML = TEMPLATE;
    this.#el = {
      input: root.querySelector('textarea'),
      inputSlot: root.querySelector('slot[name="input"]'),
      attachments: root.querySelector('.attachments'),
      controls: Array.from(root.querySelectorAll('.row > slot')).filter((slot) => slot.name !== 'input'),
      wave: root.querySelector('.wave'),
      bars: Array.from(root.querySelectorAll('.wave i')),
      file: root.querySelector('input[type="file"]'),
      status: root.querySelector('[part="status"]'),
      transcript: root.querySelector('[part="transcript"]'),
    };
    this.#wire();
  }

  connectedCallback() {
    this.#syncAttributes();
    if (this.hasAttribute('pinned')) this.#followKeyboard(true);
  }

  disconnectedCallback() {
    this.#followKeyboard(false);
    this.#release?.();
    this.cancelDictation();
    this.stopVoice();
  }

  attributeChangedCallback(name) {
    this.#syncAttributes();
    if (name === 'pinned' && this.isConnected) this.#followKeyboard(this.hasAttribute('pinned'));
  }

  get adapters() { return this.#controller.adapters; }
  set adapters(value) { this.#controller.adapters = value; }

  get onSend() { return this.#controller.onSend; }
  set onSend(handler) { this.#controller.onSend = handler; }

  get value() { return this.#controller.value; }
  set value(text) { this.#controller.value = text; }

  get attachments() { return this.#controller.attachments; }
  get disabled() { return this.hasAttribute('disabled'); }
  get state() { return this.#controller.state; }

  focus(options) { this.#draftControl().focus(options); }
  clear() { this.#controller.clear(); }
  send() { return this.#controller.send(); }
  attach(file) { return this.#controller.attach(file); }
  removeAttachment(id) { this.#controller.removeAttachment(id); }
  stopDictation() { return this.#controller.stopDictation(); }
  cancelDictation() { return this.#controller.cancelDictation(); }
  startVoice() { return this.#controller.startVoice(); }
  stopVoice() { return this.#controller.stopVoice(); }
  toggleMicMute() { return this.#controller.toggleMicMute(); }

  #draftControl() {
    return this.#el.inputSlot.assignedElements()[0] ?? this.#el.input;
  }

  startDictation(start = this.#draftControl().selectionStart ?? this.value.length, end = this.#draftControl().selectionEnd ?? start) {
    return this.#controller.startDictation(start, end);
  }

  openFilePicker() {
    const { hidden, disabled } = this.state.controls.attach;
    if (!hidden && !disabled) this.#el.file.click();
  }

  #emit(type, detail) {
    this.dispatchEvent(new CustomEvent(type, { detail, bubbles: true, composed: true }));
  }

  #wire() {
    const { input, file } = this.#el;
    const fallback = (name) => this.shadowRoot.querySelector(`slot[name="${name}"] button`);

    for (const type of ['aiur-send', 'aiur-conversation-state', 'aiur-conversation-error']) {
      this.#controller.addEventListener(type, ({ detail }) => {
        if (type === 'aiur-conversation-state') this.#render(detail);
        this.#emit(type, detail);
        if (type === 'aiur-conversation-error') this.#emit('aiur-composer-error', detail);
      });
    }

    input.addEventListener('input', () => {
      this.value = input.value;
      this.#resize();
    });
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.send();
      }
    });
    const escape = (event) => {
      if (event.key === 'Escape' && this.state.dictation === 'recording') this.cancelDictation();
    };
    this.shadowRoot.addEventListener('keydown', escape);
    this.addEventListener('keydown', escape);

    fallback('send').addEventListener('click', () => this.send());
    fallback('attach').addEventListener('click', () => this.openFilePicker());
    file.addEventListener('change', () => {
      for (const picked of file.files ?? []) this.attach(picked);
      file.value = '';
    });

    // The mic hides during dictation, so the release is caught on the window.
    const mic = fallback('mic');
    mic.addEventListener('pointerdown', (event) => {
      if (event.button > 0 || mic.disabled) return;
      event.preventDefault();
      if (this.state.dictation === 'recording' || this.state.voice === 'live') {
        this.toggleMicMute();
        return;
      }
      const pressedAt = Date.now();
      this.startDictation();
      if (this.state.dictation !== 'recording') return;
      const win = this.ownerDocument.defaultView;
      const release = (up) => {
        if (up.pointerId !== event.pointerId) return;
        this.#release();
        if (Date.now() - pressedAt >= HOLD_MS) this.stopDictation();
      };
      this.#release = () => {
        win.removeEventListener('pointerup', release);
        win.removeEventListener('pointercancel', release);
        this.#release = null;
      };
      win.addEventListener('pointerup', release);
      win.addEventListener('pointercancel', release);
    });
    // A touch must not activate the stop button that replaced the mic.
    mic.addEventListener('touchstart', (event) => event.preventDefault(), { passive: false });
    mic.addEventListener('contextmenu', (event) => event.preventDefault());
    mic.addEventListener('click', (event) => {
      if (event.detail > 0) return;
      if (this.state.dictation === 'recording' || this.state.voice === 'live') {
        this.toggleMicMute();
        return;
      }
      this.startDictation();
      if (this.state.dictation === 'recording') {
        const stop = this.#el.controls.find((slot) => slot.name === 'stop');
        (stop.assignedElements()[0] ?? fallback('stop')).focus();
      }
    });

    fallback('stop').addEventListener('click', () => this.stopDictation());
    fallback('cancel').addEventListener('click', () => this.cancelDictation());
    fallback('voice').addEventListener('click', () => (
      this.state.voice === 'live' ? this.stopVoice() : this.startVoice()
    ));
  }

  #syncAttributes() {
    const { input, file } = this.#el;
    input.placeholder = this.getAttribute('placeholder') ?? '';
    const accept = this.getAttribute('accept');
    if (accept) file.setAttribute('accept', accept);
    else file.removeAttribute('accept');
    this.#controller.disabled = this.disabled;
  }

  #render(state) {
    const { input, wave, bars, status, attachments, controls, transcript } = this.#el;
    const recording = state.dictation === 'recording';
    const active = this.shadowRoot.activeElement ?? this.ownerDocument.activeElement;
    const activeSlot = active?.assignedSlot ?? active?.closest('slot');
    if (!recording) this.#release?.();

    for (const slot of controls) {
      const control = state.controls[slot.name];
      const button = slot.firstElementChild;
      slot.hidden = control.hidden;
      button.disabled = control.disabled;
      button.setAttribute('aria-label', control.label);
      if (control.pressed !== undefined) button.setAttribute('aria-pressed', String(control.pressed));
      if (slot.name === 'mic') {
        button.innerHTML = iconMarkup(control.label === 'Unmute microphone' ? 'micMuted' : 'mic')
          .replace('micMuted-icon', 'mic-icon');
      }
    }
    controls.find((slot) => slot.name === 'voice').hidden = !(recording || state.voice !== 'idle') || !this.adapters.voice;

    if (input.value !== state.value) {
      input.value = state.value;
      if (state.caret !== null) input.setSelectionRange(state.caret, state.caret);
      this.#resize();
    }
    input.disabled = state.disabled;
    input.readOnly = state.readOnly;
    input.setAttribute('aria-label', state.inputLabel);
    if (activeSlot?.hidden) this.focus();
    wave.hidden = !recording && state.voice !== 'live';
    transcript.replaceChildren(...state.voiceTranscript.map(({ speaker, text }) => {
      const line = this.ownerDocument.createElement('p');
      line.dataset.speaker = speaker;
      line.setAttribute('part', `transcript-bubble transcript-bubble-${speaker}`);
      line.textContent = text;
      return line;
    }));
    bars.forEach((bar, index) => {
      bar.style.transform = `scaleY(${Math.max(0.1, state.levels[index]).toFixed(2)})`;
    });

    this.setAttribute('data-dictation-state', state.dictation);
    this.setAttribute('data-voice-state', state.voice);
    this.toggleAttribute('data-sending', state.sending);
    this.toggleAttribute('data-recording', recording);
    this.toggleAttribute('data-voice-live', state.voice === 'live');
    if (state.error) this.setAttribute('data-error-code', state.error.code);
    else this.removeAttribute('data-error-code');
    if (status.textContent !== state.announcement) status.textContent = state.announcement;

    // Keep attachment controls stable while the user types or the waveform updates.
    const ids = new Set(state.attachments.map((item) => String(item.id)));
    for (const chip of Array.from(attachments.children)) {
      if (!ids.has(chip.dataset.id)) chip.remove();
    }
    for (const item of state.attachments) {
      const chip = attachments.querySelector(`[data-id="${item.id}"]`);
      if (chip?.dataset.state === item.state) {
        const remove = chip.querySelector('button');
        if (remove) remove.disabled = state.disabled;
        continue;
      }
      const next = this.#chip(item);
      if (chip) chip.replaceWith(next);
      else attachments.append(next);
    }
  }

  #chip(item) {
    const chip = this.ownerDocument.createElement('span');
    chip.className = 'chip';
    chip.setAttribute('part', 'attachment');
    chip.dataset.id = item.id;
    chip.dataset.state = item.state;
    const name = this.ownerDocument.createElement('span');
    name.setAttribute('part', 'attachment-name');
    name.textContent = item.name;
    chip.append(name);

    if (item.state === 'ready') {
      const remove = this.ownerDocument.createElement('button');
      remove.type = 'button';
      remove.disabled = this.disabled;
      remove.setAttribute('part', 'remove-attachment');
      remove.setAttribute('aria-label', `Remove ${item.name}`);
      remove.innerHTML = iconMarkup('cancel');
      remove.addEventListener('click', () => {
        this.removeAttachment(item.id);
        this.focus();
      });
      const slot = this.ownerDocument.createElement('slot');
      slot.name = `remove-attachment-${item.id}`;
      slot.append(remove);
      chip.append(slot);
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
