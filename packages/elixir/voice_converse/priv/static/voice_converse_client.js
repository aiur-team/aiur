// A no-build browser client for the v1 VoiceConverse wire protocol.
const VERSION = 1;
const PCM_RATE = 16_000;
const WORKLET_SOURCE = `class VoiceCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0]?.[0];
    if (channel) this.port.postMessage(channel.slice());
    return true;
  }
}
registerProcessor("voice-capture", VoiceCaptureProcessor);`;

export class VoiceConverseClient {
  constructor({ url, target, draftContainer, view = globalThis.document, onFrame = () => {}, onError = () => {} }) {
    this.url = url;
    this.target = target;
    this.draftContainer = draftContainer;
    this.view = view;
    this.onFrame = onFrame;
    this.onError = onError;
    this.socket = null;
    this.audioContext = null;
    this.mediaStream = null;
    this.captureNodes = [];
    this.playback = [];
    this.playing = null;
    this.playbackClock = null;
    this.playbackElement = this.view?.querySelector("#assistant-audio") || null;
    this.drafts = new Map();
    this.textOnly = false;
    this.browserStt = false;
    this.localBargeIn = false;
    this.stoppedTurns = new Set();
    this.speechRecognition = null;
  }

  bindStart(button) {
    button.addEventListener("click", () => this.startFromClick().catch((error) => this.fail(error)));
  }

  bindPage() {
    const modeButtons = [...this.view?.querySelectorAll("[data-mode]")];
    modeButtons.forEach((button) => button.addEventListener("click", () => this.selectMode(button.dataset.mode)));
    this.bindStart(this.view.querySelector("#start"));
    this.view.querySelector("#start-text")?.addEventListener("click", () => this.startFromClick().catch((error) => this.fail(error)));
    this.view.querySelector("#end")?.addEventListener("click", () => this.end());
    this.view.querySelector("#end-text")?.addEventListener("click", () => this.end());
    this.view?.querySelector("#mute")?.addEventListener("click", (event) => this.toggleMute(event.currentTarget));
    const form = this.view?.querySelector("#text-form");
    const input = this.view?.querySelector("#message-input");
    form?.addEventListener("submit", (event) => {
      event.preventDefault();
      if (input.value.trim()) this.send({ type: "text", text: input.value.trim() });
      input.focus();
    });
    input?.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        form.requestSubmit();
      }
    });
    this.view?.querySelector("#speak-replies")?.addEventListener("change", (event) => {
      this.speakReplies = event.currentTarget.checked;
    });
    this.selectMode("voice");
  }

  selectMode(mode) {
    this.textOnly = mode === "text";
    this.view?.querySelectorAll("[data-mode]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    });
    this.view?.querySelector("#voice-controls")?.toggleAttribute("hidden", this.textOnly);
    this.view?.querySelector("#text-controls")?.toggleAttribute("hidden", !this.textOnly);
    if (this.textOnly) this.view?.querySelector("#message-input")?.focus();
  }

  async startFromClick() {
    this.ended = false;
    if (!this.textOnly && !this.browserStt) await this.startCapture();

    try {
      await this.connect();
      this.send({ type: "start", target: this.target });
      if (!this.textOnly) this.startSpeechRecognition();
      this.view.querySelector("#start").disabled = true;
      if (this.view?.querySelector("#start-text")) this.view.querySelector("#start-text").disabled = true;
      this.view.querySelector("#end").disabled = false;
      this.view?.querySelector("#mute") && (this.view.querySelector("#mute").disabled = false);
      if (this.view?.querySelector("#end-text")) this.view.querySelector("#end-text").disabled = false;
      if (this.textOnly) this.view?.querySelector("#message-input").focus();
    } catch (error) {
      this.stopCapture();
      this.stopSpeechRecognition();
      throw error;
    }
  }

  connect() {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) return Promise.resolve();

    return new Promise((resolve, reject) => {
      const socket = new WebSocket(this.url);
      this.socket = socket;
      let opened = false;
      socket.addEventListener("open", () => {
        opened = true;
        resolve();
      }, { once: true });
      socket.addEventListener("error", () => reject(new Error("Voice socket connection failed.")), { once: true });
      socket.addEventListener("message", (event) => this.receive(event));
      socket.addEventListener("close", () => {
        this.stopCapture();
        this.stopSpeechRecognition();
        this.stopPlayback();
        if (!opened) reject(new Error("Voice socket connection was rejected."));
      });
    });
  }

  send(frame) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Voice socket is not connected.");
    }
    this.socket.send(JSON.stringify({ v: VERSION, ...frame }));
  }

  end() {
    if (this.socket?.readyState === WebSocket.OPEN) this.send({ type: "end" });
    this.stopCapture();
    this.stopSpeechRecognition();
    this.stopPlayback();
    if (this.view?.querySelector("#end")) this.view.querySelector("#end").disabled = true;
    if (this.view?.querySelector("#mute")) this.view.querySelector("#mute").disabled = true;
    if (this.view?.querySelector("#end-text")) this.view.querySelector("#end-text").disabled = true;
    if (this.view?.querySelector("#start")) this.view.querySelector("#start").disabled = false;
    if (this.view?.querySelector("#start-text")) this.view.querySelector("#start-text").disabled = false;
    this.ended = true;
    this.setState("ended");
  }

  finishFromServer() {
    this.stopCapture();
    this.stopSpeechRecognition();
    this.stopPlayback();
    if (this.view?.querySelector("#end")) this.view.querySelector("#end").disabled = true;
    if (this.view?.querySelector("#mute")) this.view.querySelector("#mute").disabled = true;
    if (this.view?.querySelector("#end-text")) this.view.querySelector("#end-text").disabled = true;
    if (this.view?.querySelector("#start")) this.view.querySelector("#start").disabled = false;
    if (this.view?.querySelector("#start-text")) this.view.querySelector("#start-text").disabled = false;
    this.ended = true;
    this.setState("ended");
  }

  async startCapture() {
    if (this.mediaStream) return;
    this.mediaStream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });

    const context = new AudioContext();
    await context.audioWorklet.addModule(URL.createObjectURL(new Blob([WORKLET_SOURCE], { type: "text/javascript" })));
    const source = context.createMediaStreamSource(this.mediaStream);
    const processor = new AudioWorkletNode(context, "voice-capture");
    const muted = context.createGain();
    muted.gain.value = 0;
    processor.port.addEventListener("message", (event) => {
      if (this.browserStt || this.socket?.readyState !== WebSocket.OPEN) return;
      const pcm = resamplePcm16(event.data, context.sampleRate, PCM_RATE);
      this.send({ type: "audio", data_b64: bytesToBase64(new Uint8Array(pcm.buffer)) });
    });
    processor.port.start();
    source.connect(processor);
    processor.connect(muted);
    muted.connect(context.destination);
    await context.resume();
    this.audioContext = context;
    this.captureNodes = [source, processor, muted];
    this.installLocalBargeIn(source, context);
  }

  installLocalBargeIn(source, context) {
    const analyser = context.createAnalyser();
    analyser.fftSize = 512;
    source.connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    const inspect = () => {
      if (this.localBargeIn && this.playing) {
        analyser.getFloatTimeDomainData(samples);
        const energy = Math.sqrt(samples.reduce((sum, sample) => sum + sample * sample, 0) / samples.length);
        if (energy > 0.035) this.stopPlayback({ report: true });
      }
      this.bargeInTimer = setTimeout(inspect, 40);
    };
    this.captureNodes.push(analyser);
    this.bargeInTimer = setTimeout(inspect, 40);
  }

  stopCapture() {
    clearTimeout(this.bargeInTimer);
    this.captureNodes.forEach((node) => node.disconnect());
    this.captureNodes = [];
    this.mediaStream?.getTracks().forEach((track) => track.stop());
    this.mediaStream = null;
    if (this.audioContext) this.audioContext.close();
    this.audioContext = null;
  }

  startSpeechRecognition() {
    if (!this.browserStt) return;
    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!Recognition) {
      this.fail(new Error("Browser speech recognition is unavailable."));
      return;
    }
    const recognition = new Recognition();
    this.browserSttSent = new Set();
    recognition.continuous = true;
    recognition.interimResults = true;
    if ("processLocally" in recognition) recognition.processLocally = true;
    recognition.addEventListener("speechstart", () => this.stopPlayback({ report: true }));
    recognition.addEventListener("result", (event) => {
      const transcript = Array.from({ length: event.results.length }, (_, index) => event.results[index][0].transcript).join("");
      const output = this.view?.querySelector("#user-transcript");
      if (output) output.textContent = transcript;
      for (let index = event.resultIndex || 0; index < event.results.length; index += 1) {
        const result = event.results[index];
        if (!result.isFinal || this.browserSttSent.has(index)) continue;
        this.browserSttSent.add(index);
        if (result[0].transcript.trim()) this.send({ type: "text", text: result[0].transcript.trim() });
      }
    });
    recognition.addEventListener("error", () => this.fail(new Error("Browser speech recognition stopped.")));
    recognition.start();
    this.speechRecognition = recognition;
  }

  stopSpeechRecognition() {
    this.speechRecognition?.stop();
    this.speechRecognition = null;
  }

  receive(event) {
    let frame;
    try {
      frame = JSON.parse(event.data);
    } catch (_error) {
      this.fail(new Error("Voice socket sent invalid JSON."));
      return;
    }
    if (frame.v !== VERSION || typeof frame.type !== "string") {
      this.fail(new Error("Voice socket sent an unsupported frame."));
      return;
    }

    if (frame.type === "state" && !this.ended) this.setState(frame.state);
    if (frame.type === "transcript" && this.view?.querySelector("#user-transcript")) this.view.querySelector("#user-transcript").textContent = frame.text;
    if (frame.type === "agent_text") this.receiveText(frame);
    if (frame.type === "agent_text_timing") this.receiveTiming(frame);
    if (frame.type === "agent_audio") this.enqueueAudio(frame);
    if (frame.type === "interrupted") this.stopPlayback({ report: true, turnId: frame.turn_id });
    if (frame.type === "draft") this.renderDraft(frame);
    if (frame.type === "delivery") this.updateDraft(frame);
    if (frame.type === "session_info") this.renderSessionInfo(frame);
    if (frame.type === "error") this.fail(new Error(frame.message));
    if (frame.type === "ended") this.finishFromServer();
    this.onFrame(frame);
  }

  receiveText(frame) {
    const output = this.view?.querySelector("#assistant-text");
    if (!output) return;
    const current = this.turns?.get(frame.turn_id) || { text: "", revealed: 0, spans: null, start: null };
    current.text += frame.text;
    if (!this.turns) this.turns = new Map();
    this.turns.set(frame.turn_id, current);
    if (!current.spans) current.revealed = graphemeLength(current.text);
    this.renderRevealed(output, current);
    if (frame.final && this.speakReplies) this.speak(current.text);
  }

  receiveTiming(frame) {
    if (this.textOnly) return;
    if (!this.turns) this.turns = new Map();
    const turn = this.turns.get(frame.turn_id) || { text: "", revealed: 0, spans: [], start: null };
    if (frame.chars) {
      let end = Math.max(0, graphemeLength(turn.text) - graphemeLength(frame.text));
      turn.spans ||= [];
      for (const span of frame.chars) {
        end += span.length;
        turn.spans.push({ offset: frame.audio_offset_ms + span.offset_ms, end });
      }
      if (turn.start === null) turn.start = this.playbackClock?.startedAt ?? this.audioContext?.currentTime ?? null;
    } else {
      turn.spans = null;
    }
    this.turns.set(frame.turn_id, turn);
    if (!turn.spans) {
      turn.revealed = graphemeLength(turn.text);
      this.renderRevealed(this.view?.querySelector("#assistant-text"), turn);
      return;
    }
    this.revealOnClock(frame.turn_id, turn);
  }

  revealOnClock(id, turn) {
    const reveal = () => {
      if (this.turns?.get(id) !== turn) return;
      const elapsed = Math.max(0, ((this.audioContext?.currentTime ?? turn.start) - turn.start) * 1000);
      for (const span of turn.spans) {
        if (span.offset <= elapsed) turn.revealed = Math.max(turn.revealed, span.end);
      }
      this.renderRevealed(this.view?.querySelector("#assistant-text"), turn);
      if (turn.revealed < turn.text.length) turn.revealTimer = requestAnimationFrame(reveal);
    };
    cancelAnimationFrame(turn.revealTimer);
    turn.revealTimer = requestAnimationFrame(reveal);
  }

  renderRevealed(output, turn) {
    if (output) output.textContent = sliceGraphemes(turn.text, turn.revealed);
  }

  enqueueAudio(frame) {
    if (this.textOnly) return;
    this.playback.push(frame);
    if (!this.playing) this.playNext();
  }

  async playNext() {
    const frame = this.playback.shift();
    if (!frame) return;
    const match = /^pcm_(\d+)$/.exec(frame.format);
    if (!match) return this.playNext();
    this.audioContext ||= new AudioContext();
    const context = this.audioContext;
    if (!this.playbackClock) {
      const destination = context.createMediaStreamDestination();
      this.playbackElement.srcObject = destination.stream;
      this.playbackClock = { destination, nextTime: context.currentTime, turnId: frame.turn_id, startedAt: null };
      await this.playbackElement.play();
    }
    const clock = this.playbackClock;
    if (clock.turnId !== frame.turn_id) {
      clock.turnId = frame.turn_id;
      clock.startedAt = null;
      clock.nextTime = context.currentTime;
    }
    const bytes = base64ToBytes(frame.data_b64);
    const samples = new Int16Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.byteLength / 2));
    const buffer = context.createBuffer(1, samples.length, Number(match[1]));
    const channel = buffer.getChannelData(0);
    samples.forEach((sample, index) => (channel[index] = sample / 32768));
    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(clock.destination);
    const startAt = Math.max(context.currentTime, clock.nextTime);
    clock.startedAt ??= startAt;
    this.playing = source;
    source.addEventListener("ended", () => {
      if (this.playing === source) {
        this.playing = null;
        this.playNext();
      }
    });
    source.start(startAt);
    clock.nextTime = startAt + buffer.duration;
  }

  stopPlayback({ report = false, turnId = this.playbackClock?.turnId } = {}) {
    const clock = this.playbackClock;
    const elapsed = clock?.startedAt === null || !clock || !this.audioContext
      ? 0
      : Math.max(0, Math.round((this.audioContext.currentTime - clock.startedAt) * 1000));
    this.playback = [];
    try { this.playing?.stop(); } catch (_error) { /* source already ended */ }
    this.playing = null;
    this.playbackClock = null;
    this.playbackElement?.pause();
    if (report && turnId && !this.stoppedTurns.has(turnId)) {
      this.stoppedTurns.add(turnId);
      const turn = this.turns?.get(turnId);
      if (turn) {
        if (turn.spans) {
          const heardEnd = turn.spans.reduce((end, span) => (span.offset < elapsed ? Math.max(end, span.end) : end), 0);
          turn.revealed = Math.min(turn.revealed, heardEnd);
        }
        cancelAnimationFrame(turn.revealTimer);
        this.renderRevealed(this.view?.querySelector("#assistant-text"), turn);
      }
      this.send({ type: "playback_state", state: "stopped", turn_id: turnId, played_until_ms: elapsed });
    }
  }

  renderDraft(frame) {
    if (!this.draftContainer) return;
    const card = this.view.createElement("article");
    card.className = "draft-card";
    const text = this.view.createElement("p");
    text.textContent = frame.status === "unknown"
      ? `${frame.text} (delivery is uncertain; the agent may still receive it)`
      : frame.text;
    const confirm = this.button("Confirm");
    const discard = this.button(frame.status === "unknown" ? "Clear" : "Discard");
    const edit = this.button("Edit");
    let editedText = null;
    let sent = false;
    confirm.addEventListener("click", () => {
      if (sent || frame.status === "unknown") return;
      sent = true;
      confirm.disabled = true;
      const draft = { type: "confirm_draft", draft_id: frame.draft_id };
      if (editedText !== null) draft.edited_text = editedText;
      this.send(draft);
    });
    discard.addEventListener("click", () => {
      if (sent) return;
      sent = true;
      discard.disabled = true;
      this.send({ type: "discard_draft", draft_id: frame.draft_id });
    });
    edit.addEventListener("click", () => {
      if (editedText !== null || sent) return;
      const editor = this.view.createElement("textarea");
      editor.setAttribute("aria-label", "Edit draft");
      editor.value = text.textContent;
      editor.addEventListener("input", () => { editedText = editor.value; });
      text.replaceWith(editor);
      edit.disabled = true;
      editor.focus();
    });
    if (frame.status === "unknown") card.append(text, discard);
    else card.append(text, edit, confirm, discard);
    this.drafts.get(frame.draft_id)?.remove();
    this.drafts.set(frame.draft_id, card);
    this.draftContainer.append(card);
  }

  button(label) {
    const button = this.view.createElement("button");
    button.type = "button";
    button.textContent = label;
    return button;
  }

  updateDraft(frame) {
    const card = this.drafts.get(frame.draft_id);
    if (!card) return;
    if (["confirmed", "sent", "delivered", "failed", "discarded", "stale"].includes(frame.status)) {
      card.remove();
      this.drafts.delete(frame.draft_id);
    }
  }

  renderSessionInfo(frame) {
    const values = {
      option: frame.label,
      cost: frame.cost_estimate_usd === undefined ? null : `Estimated cost: $${Number(frame.cost_estimate_usd).toFixed(2)}`,
      session: frame.session_seconds_left === undefined ? null : `${Math.ceil(frame.session_seconds_left / 60)} min session time left`,
      daily: frame.minutes_left_today === undefined ? null : `${frame.minutes_left_today} min left today`,
      replay: frame.fork_mode === "replay" ? "Answer uses a saved summary" : null,
    };
    for (const [field, value] of Object.entries(values)) {
      const element = this.view?.querySelector(`[data-session-info="${field}"]`);
      if (!element) continue;
      element.textContent = value || "";
      element.hidden = !value;
    }
    this.localBargeIn = frame.interruption_supported === false;
  }

  setState(state) {
    const names = {
      connecting: "Connecting", listening: "Listening", thinking: "Thinking", speaking: "Speaking",
      consulting: "Consulting", reconnecting: "Reconnecting", ended: "Ended", error: "Error",
    };
    const indicator = this.view?.querySelector("#state-indicator");
    if (indicator) {
      indicator.textContent = names[state] || "Connecting";
      indicator.dataset.state = state;
    }
    const detail = this.view?.querySelector("#state-detail");
    if (detail) detail.textContent = names[state] || "Connecting";
  }

  toggleMute(button) {
    const track = this.mediaStream?.getAudioTracks()[0];
    if (!track) return;
    track.enabled = !track.enabled;
    button.setAttribute("aria-pressed", String(!track.enabled));
    button.textContent = track.enabled ? "Mute" : "Unmute";
  }

  speak(text) {
    if ("speechSynthesis" in window) window.speechSynthesis.speak(new SpeechSynthesisUtterance(text));
  }

  fail(error) {
    this.setState("error");
    const message = this.view?.querySelector("#error-message");
    if (message) message.textContent = error.message;
    this.onError(error);
  }
}

function resamplePcm16(samples, sourceRate, targetRate) {
  const outputLength = Math.max(1, Math.round((samples.length * targetRate) / sourceRate));
  const output = new Int16Array(outputLength);
  for (let index = 0; index < outputLength; index += 1) {
    const position = (index * sourceRate) / targetRate;
    const left = Math.floor(position);
    const right = Math.min(left + 1, samples.length - 1);
    const sample = samples[left] + (samples[right] - samples[left]) * (position - left);
    output[index] = Math.max(-1, Math.min(1, sample)) * 32767;
  }
  return output;
}

function bytesToBase64(bytes) {
  let text = "";
  bytes.forEach((byte) => (text += String.fromCharCode(byte)));
  return btoa(text);
}

function base64ToBytes(value) {
  const text = atob(value);
  return Uint8Array.from(text, (character) => character.charCodeAt(0));
}

function graphemeLength(text) {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)].length;
}

function sliceGraphemes(text, length) {
  return [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text)]
    .slice(0, length)
    .map((part) => part.segment)
    .join("");
}
