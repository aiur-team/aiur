(() => {
  class ExecutorVoiceController {
    constructor(root) {
      this.root = root;
      this.state = "idle";
      this.sources = new Set();
      this.onToggle = () => {
        if (this.transport && ["failed", "ending"].includes(this.state)) return;
        ["connecting", "live"].includes(this.state) ? this.stop() : this.start();
      };
    }

    bindElements() {
      this.el = this.root.querySelector("[data-executor-voice]");
      const button = this.el?.querySelector("[data-executor-voice-toggle]");
      if (button === this.button) return;
      this.button?.removeEventListener("click", this.onToggle);
      this.button = button;
      this.enabled = button && !button.disabled;
      button?.addEventListener("click", this.onToggle);
    }

    status(state, message) {
      this.state = state;
      if (!this.el) return;
      this.el.dataset.state = state;
      this.el.querySelector("[data-executor-voice-status]").textContent = message;
      this.button.disabled = !this.enabled || this.state === "ending" || (this.state === "failed" && !!this.transport);
      this.button.textContent = ["connecting", "live"].includes(state) ? "End Executor conversation" : "Talk to Executor";
    }

    async start() {
      if (this.transport) return;
      this.interrupt();
      this.el.querySelector("[data-executor-voice-receipt]").textContent = "";
      this.el.querySelector("[data-executor-voice-transcript]").textContent = "";
      const generation = this.generation = (this.generation || 0) + 1;
      const current = () => generation === this.generation;
      this.status("connecting", "Connecting to Executor voice…");
      try {
        this.playback ||= new window.AudioContext();
        await this.playback.resume();
        const stream = await window.AiurVoiceCapture.requestMicrophone(window.AiurVoiceCapture.recalledDevice());
        if (!current()) { stream.getTracks().forEach(track => track.stop()); return; }
        this.capture = new window.AiurVoiceCapture.Capture(stream, samples => {
          if (current() && this.state === "live") this.transport.push("audio", {data: window.AiurVoiceCapture.encodePcm16Base64(samples)});
        });
        this.transport = window.AiurVoiceTransport.open({
          topic: "voice:executor",
          handlers: {
            state: payload => current() && this.providerState(payload.state),
            audio: payload => current() && this.playAudio(payload),
            interruption: () => current() && this.interrupt(),
            transcript: payload => { if (current()) this.el.querySelector("[data-executor-voice-transcript]").textContent = `${payload.role}: ${payload.text}`; },
            receipt: payload => { if (current()) this.receipt(payload); },
            ended: () => current() && this.ended(),
            error: payload => current() && this.providerError(payload.reason || "Executor voice failed."),
            handoff_failed: payload => current() && this.fail(payload.reason),
          },
          onError: () => current() && this.fail("Executor voice connection failed."),
          onClose: () => { if (current() && !["ended", "failed"].includes(this.state)) this.fail("Executor voice disconnected before a handoff receipt arrived."); }
        });
        await this.transport.joined;
        if (!current() || !["connecting", "live"].includes(this.state)) return;
        await this.capture.start(current);

      } catch (error) {
        if (current()) this.fail(error.message || "Executor voice could not start.");
      }
    }

    stop() {
      this.capture?.stop();
      this.capture = null;
      this.interrupt();
      if (this.transport) {
        this.transport.push("stop");
        this.status("ending", "Ending conversation; waiting for the Executor handoff receipt…");
      } else {
        this.generation = (this.generation || 0) + 1;
        this.status("ended", "Executor voice ended.");
      }
    }

    receipt(payload) {
      this.el.querySelector("[data-executor-voice-receipt]").textContent = `Queued for Executor — receipt ${payload.id} at ${payload.at}. This does not confirm it has been read.`;
    }

    ended() {
      if (this.state !== "failed") this.status("ended", "Executor voice ended.");
      this.cleanup(false);
    }

    providerState(state) {
      if (!["connecting", "live"].includes(this.state)) return;
      if (["listening", "speaking", "thinking"].includes(state)) {
        this.status("live", "Executor voice live. End the conversation to queue its transcript and summary.");
      } else if (["connecting", "reconnecting"].includes(state)) {
        this.status("connecting", "Connecting to Executor voice…");
      }
    }

    providerError(message) {
      this.status("failed", message);
      this.capture?.stop();
      this.capture = null;
      this.interrupt();
    }

    fail(message) {
      this.status("failed", message);
      this.cleanup();
    }

    playAudio({data, format}) {
      if (!["connecting", "live"].includes(this.state)) return;
      const rate = {pcm_16000: 16000, pcm_24000: 24000, pcm_44100: 44100}[format];
      if (!rate) return this.fail("Executor voice returned an unsupported audio format.");
      const raw = window.atob(data);
      if (raw.length % 2) return this.fail("Executor voice returned invalid PCM audio.");
      const bytes = Uint8Array.from(raw, char => char.charCodeAt(0));
      const pcm = new DataView(bytes.buffer);
      const buffer = this.playback.createBuffer(1, bytes.length / 2, rate);
      const samples = buffer.getChannelData(0);
      for (let i = 0; i < samples.length; i++) samples[i] = pcm.getInt16(i * 2, true) / 32768;
      const source = this.playback.createBufferSource();
      source.buffer = buffer;
      source.connect(this.playback.destination);
      this.sources.add(source);
      source.onended = () => this.sources.delete(source);
      const at = Math.max(this.playback.currentTime, this.nextAudioAt || 0);
      source.start(at);
      this.nextAudioAt = at + buffer.duration;
    }

    interrupt() {
      for (const source of this.sources) { try { source.stop(); } catch (_) {} }
      this.sources.clear();
      this.nextAudioAt = 0;
    }

    cleanup(stopPlayback = true) {
      this.capture?.stop();
      this.capture = null;
      if (stopPlayback) this.interrupt();
      const transport = this.transport;
      this.transport = null;
      if (this.button) this.button.disabled = !this.enabled;
      transport?.close();
    }

    destroy() {
      this.generation = (this.generation || 0) + 1;
      this.button?.removeEventListener("click", this.onToggle);
      this.cleanup();
      this.playback?.close();
    }
  }
  window.AiurExecutorVoiceController = ExecutorVoiceController;
})();
