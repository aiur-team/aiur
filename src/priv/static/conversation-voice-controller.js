(() => {
  class ConversationVoiceController {
    constructor(hook) {
      this.hook = hook;
      this.generation = 0;
      this.waveform = window.AiurVoiceCapture && new window.AiurVoiceCapture.WaveformBuffer();
      this.choice = new window.AiurVoiceModeChoice(this);
      this.onConversationClick = () => this.toggle("conversation");
      this.onDeviceChange = () => this.rememberDevice();
    }

    get starting() { return this.state === "requesting_permission"; }
    get recording() { return this.state === "listening"; }
    get finishing() { return this.state === "finishing"; }
    transition(next, detail) { window.AiurVoiceInputState.transition(this, next, detail); }

    mount() {
      this.bindElements();
      this.seenReplies = new Set(this.replyElements().map((element) => element.id));
      this.drawWaveform();
      if (!window.isSecureContext) {
        this.disable("Microphone access requires HTTPS or localhost. This dashboard origin is not secure.");
      } else if (
        !navigator.mediaDevices?.getUserMedia || !window.AudioContext || !window.AudioWorkletNode ||
        !window.AiurVoiceCapture || !window.AiurVoiceTransport
      ) {
        this.disable("This browser does not support microphone dictation with the Web Audio API.");
      } else {
        this.refreshDevices();
      }
    }

    bindElements() {
      const mic = this.hook.el.querySelector("[data-voice-mic]");
      const conversation = this.hook.el.querySelector("[data-voice-conversation]");
      const device = this.hook.el.querySelector("[data-voice-device]");
      this.mic = mic;
      this.choice.bind();
      if (conversation !== this.conversation) {
        this.conversation?.removeEventListener("click", this.onConversationClick);
        this.conversation = conversation;
        this.conversation?.addEventListener("click", this.onConversationClick);
      }
      if (device !== this.device) {
        this.device?.removeEventListener("change", this.onDeviceChange);
        this.device = device;
        this.device?.addEventListener("change", this.onDeviceChange);
      }
      this.input = this.hook.el.querySelector("[data-voice-input]");
      this.send = this.hook.el.querySelector("[data-voice-send]");
      this.canvas = this.hook.el.querySelector("[data-voice-waveform]");
      this.status = this.hook.el.querySelector("[data-voice-status]");
      this.form = this.input?.closest("form");
      window.AiurVoiceInputState.availability(this);
      this.syncElements();
      this.scanReplies();
    }

    rememberDevice() {
      window.AiurVoiceCapture.rememberDevice(this.device?.value);
    }

    disable(reason) {
      this.browserUnavailable = reason;
      window.AiurVoiceInputState.availability(this);
    }

    syncElements() {
      if (this.choice.root && this.state) {
        const accepted = this.choice.root.dataset.voiceDeliveryAccepted === "true";
        this.choice.root.dataset.voiceState = accepted && ["idle", "unavailable"].includes(this.state) ? "sent" : this.state;
      }
      if (this.mic) {
        this.mic.disabled = Boolean(
          this.unavailableReason || this.starting || this.finishing || this.awaitingReply || this.speaking ||
          (this.recording && this.captureMode !== "dictation")
        );
        this.mic.setAttribute("aria-pressed", this.recording ? "true" : "false");
        this.mic.setAttribute("aria-label", this.recording ? "Stop dictation" : "Dictate message");
        this.mic.classList.toggle("rec", this.recording && this.captureMode === "dictation");
        this.mic.title = this.unavailableReason || "";
      }
      if (this.conversation) {
        this.conversation.disabled = Boolean(
          this.unavailableReason || this.starting || this.finishing || this.speaking ||
          (this.recording && this.captureMode !== "conversation")
        );
        this.conversation.setAttribute("aria-pressed", this.conversationActive ? "true" : "false");
        const conversationLabel = this.awaitingReply
          ? "Cancel waiting for voice reply"
          : this.recording && this.captureMode === "conversation"
            ? "Stop interactive voice chat"
            : "Start interactive voice chat";
        this.conversation.setAttribute("aria-label", conversationLabel);
      }
      if (this.device) {
        this.device.disabled = Boolean(this.unavailableReason || this.starting || this.recording || this.finishing);
      }
      const composerLocked = Boolean(this.starting || this.recording || this.finishing || this.awaitingReply || this.speaking);
      if (this.input) {
        if (this.recording) this.input.dataset.voiceRecording = "true";
        else delete this.input.dataset.voiceRecording;
        this.input.readOnly = composerLocked;
        this.input.setAttribute("aria-readonly", composerLocked ? "true" : "false");
      }
      if (this.send) this.send.disabled = composerLocked;
      if (this.status && this.statusMessage) {
        this.status.textContent = this.statusMessage;
        this.status.hidden = false;
        this.status.classList.toggle("bad", this.statusFailed === true);
      }
      this.choice.sync();
      this.drawWaveform();
    }

    async refreshDevices() {
      if (!this.device || !navigator.mediaDevices?.enumerateDevices) return;
      const selected = window.AiurVoiceCapture.recalledDevice();
      try {
        const microphones = await window.AiurVoiceCapture.listMicrophones();
        const options = [{ deviceId: "", label: "Default microphone" }, ...microphones];
        this.device.replaceChildren(...options.map((item, index) => {
          const option = document.createElement("option");
          option.value = item.deviceId;
          option.textContent = item.label || `Microphone ${index}`;
          return option;
        }));
        this.device.value = options.some((item) => item.deviceId === selected) ? selected : "";
      } catch (_error) {
        // Selection is an enhancement. Capture still works with the browser default.
      }
    }

    toggle(mode) {
      if (this.finishing) return;
      if (mode === "conversation" && this.awaitingReply) this.cancelConversationWait();
      else if (this.recording) this.stop();
      else this.start(mode);
    }

    async start(mode = "dictation") {
      window.AiurVoiceInputState.availability(this);
      if (this.unavailableReason || this.starting || this.recording || this.finishing || this.awaitingReply || this.speaking || this.conversationActive || !this.mic || (!this.input && !this.hook.prepareVoiceInput)) return;
      const generation = this.generation + 1;
      this.generation = generation;
      this.captureMode = mode;
      if (mode === "conversation") this.conversationActive = true;
      this.mic.disabled = true;
      this.transition("requesting_permission");

      let preparingField = true;
      try {
        await this.hook.prepareVoiceInput?.();
        if (!this.current(generation)) return;
        if (!this.input || this.input.disabled) throw new Error("The response field did not open.");
        preparingField = false;
        this.limitReached = false;
        if (mode === "conversation") {
          // Browsers generally require audio playback to be unlocked by a user
          // gesture. Create and resume the reply context while this click is
          // still active; constructing it later, when the agent reply arrives,
          // leaves it suspended and produces silent "playback".
          this.playbackContext ||= new window.AudioContext();
          await this.playbackContext.resume();
        }
        const stream = await window.AiurVoiceCapture.requestMicrophone(this.device?.value || "");
        if (!this.current(generation)) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        const capture = new window.AiurVoiceCapture.Capture(stream, (samples) => this.handleSamples(samples));
        this.capture = capture;
        const live = () => this.current(generation) && this.capture === capture;
        await this.openChannel(generation, mode);
        if (!live()) return;
        await capture.start(live);
        if (!live()) return;

        this.baseText = mode === "conversation" ? "" : (this.input?.value || "").trim();
        if (mode === "conversation" && this.input) {
          this.input.value = "";
          this.input.dispatchEvent(new Event("input", { bubbles: true }));
        }
        this.resetWaveform();
        this.transition("listening", mode === "conversation" ? { message: "Listening… press the conversation button when you are finished." } : {});
        this.syncElements();
        await this.refreshDevices();
      } catch (error) {
        if (this.generation === generation) {
          this.disposeCapture();
          this.closeChannel();
          this.resetConversationState({ resetContext: mode === "conversation" });
          window.AiurVoiceInputState.failure(this, error, preparingField);
        }
      }
    }

    current(generation) {
      return this.generation === generation && this.hook.el.isConnected;
    }

    openChannel(generation, mode) {
      let transport;
      const current = () => this.current(generation) && this.channel === transport.channel;
      const fail = (payload) => this.handleTransportFailure({ reason_code: payload?.reason_code }, generation, transport.channel);
      transport = window.AiurVoiceTransport.open({
        topic: mode === "conversation" ? "voice:conversation" : "voice:dictate",
        joinPayload: mode === "conversation" ? {} : this.choice.joinPayload(),
        handlers: {
          transcript: (payload) => current() && this.applyTranscript(payload),
          error: (payload) => current() && fail(payload),
          stopped: () => {
            if (!current()) return;
            this.clearFinishTimer();
            this.transition("ready", { message: this.readyCopy() });
            this.disposeCapture();
            if (this.captureMode === "conversation") {
              this.submitConversationTurn();
            } else {

              this.closeChannel();
            }
            this.syncElements();
          },
          audio: (payload) => current() && this.playAudio(payload),
          audio_done: () => {
            if (!current()) return;
            this.finishPlaybackWhenAudible();
          },
          audio_error: (payload) => {
            if (!current()) return;
            this.resetConversationState();
            this.closeChannel();
            this.setStatus(payload?.reason || "Voice playback failed.");
            this.syncElements();
          }
        },
        onError: () => fail({ reason_code: "transport_lost" }),
        onClose: () => fail({ reason_code: "transport_lost" })
      });
      this.socket = transport.socket;
      this.channel = transport.channel;
      return transport.joined;
    }

    stop() {
      if (!this.recording) return;
      this.transition("finishing");
      this.disposeCapture();
      this.channel?.push("stop", {});
      this.clearFinishTimer();
      this.finishTimer = window.setTimeout(() => {
        const channel = this.channel;
        if (channel) this.handleTransportFailure({ reason_code: "transport_lost" }, this.generation, channel);
      }, 5000);
    }

    handleSamples(samples) {
      if (!this.recording) return;
      this.pushWaveform(samples);
      this.channel?.push("audio", { data: window.AiurVoiceCapture.encodePcm16Base64(samples) });
    }

    pushWaveform(samples) {
      this.waveform.push(samples);
      this.drawWaveform();
    }

    resetWaveform() {
      this.waveform.reset();
      this.drawWaveform();
    }

    drawWaveform() {
      const context = this.canvas?.getContext("2d");
      const columns = this.waveform?.columns;
      if (!this.canvas || !context || !columns) return;
      const style = window.getComputedStyle(this.hook.el);
      const middle = this.canvas.height / 2;
      context.clearRect(0, 0, this.canvas.width, this.canvas.height);
      context.strokeStyle = style.getPropertyValue("--line").trim() || "#4b5563";
      context.beginPath();
      context.moveTo(0, middle + 0.5);
      context.lineTo(this.canvas.width, middle + 0.5);
      context.stroke();
      context.strokeStyle = style.getPropertyValue("--accent").trim() || "#3ba55d";
      context.lineWidth = Math.max(1, this.canvas.width / columns.length * 0.7);
      const scale = this.canvas.height * 0.43;
      columns.forEach((column, index) => {
        const x = (index + 0.5) * this.canvas.width / columns.length;
        context.beginPath();
        context.moveTo(x, middle - column.max * scale);
        context.lineTo(x, middle - column.min * scale);
        context.stroke();
      });
    }

    applyTranscript(payload) {
      if (!this.input || typeof payload?.text !== "string") return;
      const text = payload.text.trim();
      if (payload.kind === "final") this.baseText = this.joinText(this.baseText, text);
      this.input.value = this.joinText(this.baseText, payload.kind === "final" ? "" : text);
      this.input.dispatchEvent(new Event("input", { bubbles: true }));
      if (this.input.maxLength > 0 && this.input.value.length >= this.input.maxLength && this.recording) {
        this.limitReached = true;
        this.stop();
      }
    }

    readyCopy() {
      return this.limitReached ? "Response limit reached. Edit the text before recording your answer." :
        (this.hook.el.dataset.voiceReadyCopy || "Dictation ready. Review the text, then press Send.");
    }

    submitConversationTurn() {
      const text = (this.input?.value || "").trim();
      if (!text) {
        this.resetConversationState();
        this.closeChannel();
        this.setStatus("I did not hear a message. Press the conversation button and try again.");
        this.syncElements();
        return;
      }
      this.awaitingReply = true;
      this.setStatus("Sending your spoken message and waiting for the agent…");
      this.form?.requestSubmit(this.send);
    }

    cancelConversationWait() {
      this.resetConversationState();
      this.closeChannel();
      this.setStatus("Voice reply cancelled. Press the conversation button to speak again.");
      this.syncElements();
    }

    replyElements() {
      return Array.from(this.hook.el.querySelectorAll(".conversation-message-agent[data-message-complete='true']"));
    }

    scanReplies() {
      if (!this.seenReplies) return;
      const replies = this.replyElements().filter((element) => !this.seenReplies.has(element.id));
      for (const element of replies) {
        this.seenReplies.add(element.id);
      }

      if (!this.conversationActive || !this.awaitingReply || !this.channel) return;
      const text = replies
        .map((element) => element.querySelector(".conversation-message-body")?.textContent?.trim())
        .filter(Boolean)
        .join(" ");
      if (!text) return;
      this.speaking = true;
      this.setStatus("Agent replied. Playing voice…");
      this.syncElements();
      this.channel.push("speak", { text });
    }

    playAudio(payload) {
      if (typeof payload?.data !== "string") return;
      const decoded = window.atob(payload.data);
      const bytes = new Uint8Array(decoded.length + (this.audioCarry?.length || 0));
      if (this.audioCarry?.length) bytes.set(this.audioCarry, 0);
      for (let index = 0; index < decoded.length; index += 1) bytes[index + (this.audioCarry?.length || 0)] = decoded.charCodeAt(index);
      const evenLength = bytes.length - (bytes.length % 2);
      this.audioCarry = bytes.slice(evenLength);
      if (!evenLength) return;

      this.playbackContext ||= new window.AudioContext();
      const samples = evenLength / 2;
      const buffer = this.playbackContext.createBuffer(1, samples, 44100);
      const output = buffer.getChannelData(0);
      const view = new DataView(bytes.buffer, bytes.byteOffset, evenLength);
      for (let index = 0; index < samples; index += 1) output[index] = view.getInt16(index * 2, true) / 32768;
      const source = this.playbackContext.createBufferSource();
      source.buffer = buffer;
      source.connect(this.playbackContext.destination);
      this.playbackSources ||= new Set();
      this.playbackSources.add(source);
      source.onended = () => this.playbackSources?.delete(source);
      const startAt = Math.max(this.playbackContext.currentTime, this.nextPlaybackAt || 0);
      source.start(startAt);
      this.nextPlaybackAt = startAt + buffer.duration;
    }

    finishPlaybackWhenAudible() {
      this.clearPlaybackTimer();
      const remaining = Math.max(0, (this.nextPlaybackAt || 0) - (this.playbackContext?.currentTime || 0));
      this.playbackTimer = window.setTimeout(() => {
        this.playbackTimer = null;
        this.speaking = false;
        this.awaitingReply = false;
        this.conversationActive = false;
        this.audioCarry = null;
        this.nextPlaybackAt = null;
        this.clearPlaybackSources(false);
        this.closeChannel();
        this.setStatus("Reply finished. Press the conversation button to speak again.");
        this.syncElements();
      }, Math.ceil(remaining * 1000));
    }

    joinText(left, right) {
      return [left, right].filter((part) => part && part.trim()).join(" ");
    }

    handleTransportFailure(detail, generation, channel) {
      if (!this.current(generation) || this.channel !== channel) return;
      this.clearFinishTimer();
      this.resetConversationState();
      this.transition("error", detail);
      this.disposeCapture();
      this.closeChannel();
      this.syncElements();
    }

    clearFinishTimer() {
      if (this.finishTimer) window.clearTimeout(this.finishTimer);
      this.finishTimer = null;
    }

    clearPlaybackTimer() {
      if (this.playbackTimer) window.clearTimeout(this.playbackTimer);
      this.playbackTimer = null;
    }

    clearPlaybackSources(stop = true) {
      for (const source of this.playbackSources || []) {
        if (stop) {
          try { source.stop(); } catch (_error) {}
        }
        source.disconnect?.();
      }
      this.playbackSources?.clear();
    }

    resetConversationState({ resetContext = false } = {}) {
      this.clearPlaybackTimer();
      this.clearPlaybackSources();
      this.speaking = false;
      this.awaitingReply = false;
      this.conversationActive = false;
      this.audioCarry = null;
      this.nextPlaybackAt = null;
      if (resetContext) {
        this.playbackContext?.close();
        this.playbackContext = null;
      }
    }

    setStatus(message, failed = false) {
      this.statusMessage = message;
      this.statusFailed = failed;
      if (this.status) {
        this.status.textContent = message;
        this.status.hidden = !message;
        this.status.classList.toggle("bad", failed);
      }
    }

    disposeCapture() {
      this.capture?.stop();
      this.capture = null;
      this.syncElements();
    }

    closeChannel() {
      const channel = this.channel;
      const socket = this.socket;
      this.channel = this.socket = null;
      channel?.leave();
      socket?.disconnect();
    }

    destroy() {
      this.generation += 1;
      this.clearFinishTimer();
      this.resetConversationState();
      this.choice.destroy();
      this.conversation?.removeEventListener("click", this.onConversationClick);
      this.device?.removeEventListener("change", this.onDeviceChange);
      this.disposeCapture();
      this.closeChannel();
      this.playbackContext?.close();
    }
  }

  window.AiurConversationVoiceController = ConversationVoiceController;
})();
