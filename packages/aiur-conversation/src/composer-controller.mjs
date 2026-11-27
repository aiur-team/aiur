import { conversationError } from './conversation-error.mjs';

const WAVEFORM_SIZE = 24;

/** The composer state machine and adapter lifecycle, usable without a document. */
export class ComposerController extends EventTarget {
  #adapters = {};
  #value = '';
  #disabled = false;
  #caret = null;
  #attachments = [];
  #nextAttachmentId = 0;
  #uploads = 0;
  #dictation = null;
  #levels = new Array(WAVEFORM_SIZE).fill(0);
  #voice = null;
  #voiceTranscript = [];
  #sending = false;
  #error = null;

  onSend = null;

  get adapters() {
    return this.#adapters;
  }

  set adapters(value) {
    this.#adapters = value ?? {};
    this.#change();
  }

  get value() {
    return this.#value;
  }

  set value(text) {
    this.#value = String(text ?? '').replace(/\r\n?/g, '\n');
    this.#caret = null;
    this.#change();
  }

  get disabled() {
    return this.#disabled;
  }

  set disabled(value) {
    this.#disabled = Boolean(value);
    this.#change();
  }

  get attachments() {
    return this.#attachments.filter((item) => item.state === 'ready').map((item) => item.attachment);
  }

  get state() {
    const recording = this.#recording();
    const dictation = this.#dictation ? (recording ? 'recording' : 'stopping') : 'idle';
    const voice = this.#voice?.state ?? 'idle';
    const control = (label, hidden = false, disabled = this.disabled) => ({ label, hidden, disabled });
    const controls = {
      attach: control('Attach files', recording || typeof this.adapters.upload !== 'function'),
      mic: {
        ...control((voice === 'live' || recording)
          ? ((voice === 'live' ? this.#voice.muted : this.#dictation.muted) ? 'Unmute microphone' : 'Mute microphone')
          : 'Dictate', voice === 'idle' ? dictation === 'stopping' || dictation === 'idle' && !this.adapters.dictation : voice !== 'live'),
        pressed: voice === 'live' ? !this.#voice.muted : recording && !this.#dictation.muted,
      },
      cancel: control('Cancel dictation', !recording, false),
      voice: {
        ...control(voice === 'live' ? 'End voice conversation' : 'Switch to voice conversation',
          !this.adapters.voice || !(recording || voice !== 'idle'),
          this.disabled || voice === 'starting' || voice === 'stopping'),
        pressed: voice === 'live',
      },
      stop: control('Stop dictation', !recording, false),
      send: control(recording ? 'Stop and send' : 'Send', false, !this.#canSend()),
    };
    const attachments = this.#attachments.map(({ id, name, state, attachment }) => ({
      id, name: attachment?.name ?? name, state,
    }));
    return {
      value: this.value,
      disabled: this.disabled,
      caret: this.#caret,
      dictation,
      voice,
      voiceTranscript: this.#voiceTranscript.map((turn) => ({ ...turn })),
      sending: this.#sending,
      readOnly: dictation !== 'idle',
      attachments,
      levels: this.#levels.slice(),
      error: this.#error,
      announcement: this.#error?.message ?? ({
        recording: 'Dictating',
        stopping: voice === 'idle' ? 'Finishing dictation' : 'Ending voice conversation',
        starting: 'Connecting voice conversation',
        live: 'Voice conversation active',
      }[voice === 'idle' ? dictation : voice] ?? (this.#uploads ? 'Uploading attachments' : '')),
      inputLabel: 'Message',
      controls,
      focusOrder: [
        ...attachments.filter((item) => item.state === 'ready' && !this.disabled)
          .map((item) => `remove-attachment-${item.id}`),
        ...['attach', 'input', 'cancel', 'mic', 'voice', 'stop', 'send'].filter((name) =>
          name === 'input' ? !this.disabled : !controls[name].hidden && !controls[name].disabled),
      ],
    };
  }

  clear() {
    this.#attachments = [];
    this.#error = null;
    this.value = '';
  }

  removeAttachment(id) {
    if (this.disabled) return;
    this.#attachments = this.#attachments.filter((item) => item.id !== id || item.state !== 'ready');
    this.#change();
  }

  stopDictation() {
    return this.#endDictation('stop');
  }

  cancelDictation() {
    return this.#endDictation('cancel');
  }

  #emit(type, detail) {
    this.dispatchEvent(Object.assign(new Event(type), { detail }));
  }

  #change() {
    this.#emit('aiur-conversation-state', this.state);
  }

  #fail(action, error) {
    this.#error = conversationError(action, error);
    const detail = this.#error;
    this.#change();
    this.#emit('aiur-conversation-error', detail);
  }

  /** Sends the draft, as the send button does. While dictating, it stops dictation first. */
  async send() {
    if (!this.#canSend()) return false;
    if (this.#recording()) return this.#endDictation('send');
    const draft = this.value;
    const text = draft.trim();
    const sentItems = this.#attachments.slice();
    const attachments = this.attachments;
    const detail = { text, attachments: attachments.slice() };

    this.#error = null;
    this.#sending = true;
    this.#change();
    this.#emit('aiur-send', detail);
    try {
      if (typeof this.onSend === 'function') await this.onSend(text, attachments);
      this.#attachments = this.#attachments.filter((item) => !sentItems.includes(item));
      if (this.value === draft && !this.#dictation) this.value = '';
      return true;
    } catch (error) {
      this.#fail('send', error);
      return false;
    } finally {
      this.#sending = false;
      this.#change();
    }
  }

  async attach(file) {
    const upload = this.#adapters.upload;
    if (typeof upload !== 'function' || this.disabled || this.#recording()) return false;

    this.#error = null;
    const item = { id: this.#nextAttachmentId++, name: file.name, state: 'uploading', attachment: null };
    this.#attachments.push(item);
    this.#uploads += 1;
    this.#change();

    try {
      item.attachment = await upload(file);
      item.state = 'ready';
      return this.#attachments.includes(item);
    } catch (error) {
      this.#attachments = this.#attachments.filter((other) => other !== item);
      this.#fail('upload', error);
      return false;
    } finally {
      this.#uploads -= 1;
      this.#change();
    }
  }

  #recording() {
    return Boolean(this.#dictation && !this.#dictation.end);
  }

  async startDictation(start = this.value.length, end = start) {
    const adapter = this.#adapters.dictation;
    if (!adapter || this.#dictation || this.#voice || this.disabled) return;

    this.#error = null;
    const dictation = {
      before: this.value.slice(0, start), selected: this.value.slice(start, end),
      after: this.value.slice(end), text: '', end: null,
    };
    this.#dictation = dictation;
    dictation.ready = Promise.resolve().then(() => adapter.start({
        onPartial: (text) => {
          if (this.#dictation === dictation && !dictation.end) this.#show(dictation, String(text ?? '').trim());
        },
        onLevel: (level) => {
          if (this.#dictation === dictation && !dictation.end) this.#level(level);
        },
    })).then((session) => {
      if (typeof session?.setMuted !== 'function') throw new TypeError('dictation session must provide setMuted');
      dictation.session = session;
      if (dictation.muted) session.setMuted(true);
      return session;
    }).catch((error) => {
      this.#dictation = null;
      this.#show(dictation, '');
      this.#fail('dictation', error);
      return null;
    });
    this.#level(null);
    await dictation.ready;
  }

  /** `how` is 'stop', 'send', 'cancel' or 'voice'. */
  async #endDictation(how) {
    const dictation = this.#dictation;
    if (!dictation || dictation.end) return false;
    dictation.end = how;
    if (how === 'cancel') this.#show(dictation, '');
    else this.#change();
    const session = dictation.session ?? await dictation.ready;
    if (!session) return false;

    if (how === 'cancel') {
      try {
        if (session.cancel) await session.cancel();
        else await session.stop();
      } catch (error) {
        this.#fail('dictation', error);
      } finally {
        this.#dictation = null;
        this.#change();
      }
      return true;
    }

    let text = dictation.text;
    try {
      const final = await session.stop();
      if (typeof final === 'string' && final.trim()) text = final.trim();
    } catch (error) {
      this.#fail('dictation', error);
    }
    this.#dictation = null;
    this.#show(dictation, text);

    if (dictation.end === 'send') return this.send();
    if (dictation.end === 'voice') return this.startVoice();
    return true;
  }

  // Puts the dictated text between what was before and after the cursor.
  #show(dictation, text) {
    const { before, selected, after } = dictation;
    const lead = text && before && !/\s$/.test(before) ? ' ' : '';
    const trail = text && after && !/^\s/.test(after) ? ' ' : '';
    dictation.text = text;
    this.#value = before + (text ? lead + text + trail : selected) + after;
    this.#caret = (before + lead + text).length;
    this.#change();
  }

  // Scrolls the waveform by one bar; `null` flattens it.
  #level(level) {
    if (level === null) this.#levels.fill(0);
    else {
      this.#levels.shift();
      this.#levels.push(Math.min(1, Math.max(0, Number(level) || 0)));
    }
    this.#change();
  }

  async startVoice() {
    const adapter = this.#adapters.voice;
    if (!adapter || this.#voice || this.disabled) return false;
    if (this.#recording()) return this.#endDictation('voice');
    if (this.#dictation) return false;

    // Fence callbacks and late starts by the identity of their own session.
    const voice = { state: 'starting', session: null, muted: false };
    const draft = this.value;
    this.#error = null;
    this.#voiceTranscript = [];
    this.#voice = voice;
    this.value = '';
    try {
      voice.session = await adapter.start({
        initialText: draft.trim(),
        onPartial: (speaker, text) => {
          if (this.#voice !== voice || voice.state === 'stopping') return;
          const turn = { speaker: speaker === 'agent' ? 'agent' : 'user', text: String(text ?? '') };
          const last = [...this.#voiceTranscript].reverse().find((item) => item.speaker === turn.speaker);
          if (last) last.text = turn.text;
          else this.#voiceTranscript.push(turn);
          this.#change();
        },
        onLevel: (level) => {
          if (this.#voice === voice && voice.state !== 'stopping') this.#level(level);
        },
        onEnd: () => {
          if (this.#voice !== voice) return;
          this.#voice = null;
          this.#change();
        },
      });
      if (typeof voice.session?.setMuted !== 'function') throw new TypeError('voice session must provide setMuted');
      if (voice.muted) voice.session.setMuted(true);
      if (this.#voice !== voice) return false;
      if (voice.state === 'stopping') {
        await this.#finishVoice(voice);
        return false;
      }
      voice.state = 'live';
      this.#change();
      return true;
    } catch (error) {
      if (this.#voice === voice) {
        this.#voice = null;
        this.value = [draft, this.value].filter(Boolean).join(' ');
        this.#fail('voice', error);
      }
      return false;
    }
  }

  toggleMicMute() {
    const voice = this.#voice;
    const dictation = this.#dictation;
    if (voice?.state === 'live') {
      voice.muted = !voice.muted;
      voice.session?.setMuted(voice.muted);
    } else if (this.#recording()) {
      dictation.muted = !dictation.muted;
      dictation.session?.setMuted(dictation.muted);
    } else return false;
    this.#change();
    return voice?.state === 'live' ? voice.muted : dictation.muted;
  }

  async stopVoice() {
    if (this.#dictation?.end === 'voice') this.#dictation.end = 'stop';
    const voice = this.#voice;
    if (!voice || voice.state === 'stopping') return;
    voice.state = 'stopping';
    this.#change();
    if (voice.session) await this.#finishVoice(voice);
  }

  async #finishVoice(voice) {
    try {
      await voice.session.stop();
    } catch (error) {
      this.#fail('voice', error);
    } finally {
      if (this.#voice === voice) {
        this.#voice = null;
        this.#change();
      }
    }
  }

  #canSend() {
    if (this.#recording()) return this.#uploads === 0 && !this.#sending && !this.disabled;
    const hasContent = this.value.trim() !== '' || this.attachments.length > 0;
    return hasContent && !this.#dictation && this.#uploads === 0 && !this.#sending && !this.disabled;
  }

}
