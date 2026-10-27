// A no-build browser client for the v1 VoiceConverse wire protocol.
// Import it from a host page, then call bindStart() on a user-activated button.

const VERSION = 1;
const PCM_RATE = 16_000;

export class VoiceConverseClient {
  constructor({ url, target, draftContainer, onFrame = () => {}, onError = () => {} }) {
    this.url = url;
    this.target = target;
    this.draftContainer = draftContainer;
    this.onFrame = onFrame;
    this.onError = onError;
    this.socket = null;
    this.audioContext = null;
    this.mediaStream = null;
    this.captureNodes = [];
    this.playback = [];
    this.playing = null;
    this.drafts = new Map();
  }

  bindStart(button) {
    button.addEventListener("click", () => this.startFromClick().catch((error) => this.fail(error)));
  }

  async startFromClick() {
    // This call deliberately happens only in the click path. Browsers reject it otherwise.
    try {
      await this.startCapture();
      await this.connect();
      this.send({ type: "start", target: this.target });
    } catch (error) {
      this.stopCapture();
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
    this.stopPlayback();
  }

  async startCapture() {
    if (this.mediaStream) return;

    this.mediaStream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true },
    });

    const context = new AudioContext();
    const source = context.createMediaStreamSource(this.mediaStream);
    const processor = context.createScriptProcessor(4096, 1, 1);
    const muted = context.createGain();
    muted.gain.value = 0;

    processor.addEventListener("audioprocess", (event) => {
      if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;

      const samples = event.inputBuffer.getChannelData(0);
      const pcm16 = resamplePcm16(samples, context.sampleRate, PCM_RATE);
      this.send({ type: "audio", data_b64: bytesToBase64(new Uint8Array(pcm16.buffer)) });
    });

    source.connect(processor);
    processor.connect(muted);
    muted.connect(context.destination);
    await context.resume();
    this.audioContext = context;
    this.captureNodes = [source, processor, muted];
  }

  stopCapture() {
    this.captureNodes.forEach((node) => node.disconnect());
    this.captureNodes = [];
    this.mediaStream?.getTracks().forEach((track) => track.stop());
    this.mediaStream = null;
    this.audioContext?.close();
    this.audioContext = null;
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

    if (frame.type === "agent_audio") this.enqueueAudio(frame);
    if (frame.type === "interrupted") this.stopPlayback();
    if (frame.type === "draft") this.renderDraft(frame);
    if (frame.type === "delivery") this.updateDraft(frame);
    if (frame.type === "error") this.fail(new Error(frame.message));
    this.onFrame(frame);
  }

  enqueueAudio(frame) {
    this.playback.push(frame);
    if (!this.playing) this.playNext();
  }

  playNext() {
    const frame = this.playback.shift();
    if (!frame) return;

    const match = /^pcm_(\d+)$/.exec(frame.format);
    if (!match) return this.playNext();

    const context = this.audioContext || new AudioContext();
    const bytes = base64ToBytes(frame.data_b64);
    const samples = new Int16Array(bytes.buffer, bytes.byteOffset, Math.floor(bytes.byteLength / 2));
    const buffer = context.createBuffer(1, samples.length, Number(match[1]));
    const channel = buffer.getChannelData(0);
    samples.forEach((sample, index) => (channel[index] = sample / 32768));

    const source = context.createBufferSource();
    source.buffer = buffer;
    source.connect(context.destination);
    source.addEventListener("ended", () => {
      if (this.playing === source) {
        this.playing = null;
        this.playNext();
      }
    });
    this.playing = source;
    source.start();
  }

  stopPlayback() {
    this.playback = [];
    this.playing?.stop();
    this.playing = null;
  }

  renderDraft(frame) {
    if (!this.draftContainer) return;

    const card = document.createElement("article");
    const text = document.createElement("p");
    const confirm = document.createElement("button");
    const discard = document.createElement("button");
    text.textContent = frame.text;
    confirm.type = discard.type = "button";
    confirm.textContent = "Confirm";
    discard.textContent = "Discard";
    confirm.addEventListener("click", () => {
      confirm.disabled = true;
      this.send({ type: "confirm_draft", draft_id: frame.draft_id });
    });
    discard.addEventListener("click", () => {
      discard.disabled = true;
      this.send({ type: "discard_draft", draft_id: frame.draft_id });
    });
    card.append(text, confirm, discard);
    this.drafts.get(frame.draft_id)?.remove();
    this.drafts.set(frame.draft_id, card);
    this.draftContainer.append(card);
  }

  updateDraft(frame) {
    const card = this.drafts.get(frame.draft_id);
    if (!card) return;
    if (["delivered", "failed", "discarded"].includes(frame.status)) card.remove();
  }

  fail(error) {
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
