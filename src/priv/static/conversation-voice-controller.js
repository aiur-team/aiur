(() => {
  class ConversationVoiceController {
    constructor(hook) {
      this.hook = hook;
      this.generation = 0;
      this.waveform = window.AiurVoiceCapture && new window.AiurVoiceCapture.WaveformBuffer();
      this.onMicClick = () => this.toggle("dictation");
      this.onConversationClick = () => this.toggle("conversation");
      this.onDeviceChange = () => this.rememberDevice();
    }

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

      if (mic !== this.mic) {
        this.mic?.removeEventListener("click", this.onMicClick);
        this.mic = mic;
        this.mic?.addEventListener("click", this.onMicClick);
      }
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
      this.syncElements();
      this.scanReplies();
    }

    rememberDevice() {
      window.AiurVoiceCapture.rememberDevice(this.device?.value);
    }

    disable(reason) {
      this.unavailableReason = reason;
      this.setStatus(reason);
      this.syncElements();
    }

    syncElements() {
      if (this.mic) {
        this.mic.disabled = Boolean(
          this.unavailableReason || this.starting || this.finishing || this.awaitingReply || this.speaking ||
          (this.recording && this.captureMode !== "dictation")
        );
        this.mic.setAttribute("aria-pressed", this.recording ? "true" : "false");
        this.mic.setAttribute("aria-label", this.recording ? "Stop dictation" : "Dictate message");
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
        this.input.readOnly = composerLocked;
        this.input.setAttribute("aria-readonly", composerLocked ? "true" : "false");
      }
      if (this.send) this.send.disabled = composerLocked;
      if (this.status && this.statusMessage) this.status.textContent = this.statusMessage;
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
      if (this.starting || this.recording || this.finishing || this.awaitingReply || this.speaking || this.conversationActive || !this.mic) return;
      const generation = this.generation + 1;
      this.generation = generation;
      this.starting = true;
      this.captureMode = mode;
      if (mode === "conversation") this.conversationActive = true;
      this.mic.disabled = true;
      this.setStatus("Requesting microphone permission…");

      try {
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

        this.recording = true;
        this.baseText = mode === "conversation" ? "" : (this.input?.value || "").trim();
        if (mode === "conversation" && this.input) {
          this.input.value = "";
          this.input.dispatchEvent(new Event("input", { bubbles: true }));
        }
        this.resetWaveform();
        this.setStatus(mode === "conversation" ? "Listening… press the conversation button when you are finished." : "Listening… press the microphone again when you are finished.");
        this.syncElements();
        await this.refreshDevices();
      } catch (error) {
        if (this.generation === generation) {
          this.disposeCapture();
          this.closeChannel();
          this.resetConversationState({ resetContext: mode === "conversation" });
          this.explainFailure(error);
        }
      } finally {
        if (this.generation === generation) {
          this.starting = false;
          this.syncElements();
        }
      }
    }

    current(generation) {
      return this.generation === generation && this.hook.el.isConnected;
    }

    openChannel(generation, mode) {
      let transport;
      const current = () => this.current(generation) && this.channel === transport.channel;
      const fail = (message) => this.handleTransportFailure(message, generation, transport.channel);
      transport = window.AiurVoiceTransport.open({
        topic: mode === "conversation" ? "voice:conversation" : "voice:dictation",
        handlers: {
          transcript: (payload) => current() && this.applyTranscript(payload),
          error: (payload) => current() && fail(payload?.reason || "Speech-to-text failed."),
          stopped: () => {
            if (!current()) return;
            this.clearFinishTimer();
            this.finishing = false;
            if (this.captureMode === "conversation") {
              this.submitConversationTurn();
            } else {
              this.setStatus("Dictation ready. Review the text, then press Send.");
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
        onError: () => fail("Speech-to-text connection was lost. Try dictation again."),
        onClose: () => fail("Speech-to-text connection closed. Try dictation again.")
      });
      this.socket = transport.socket;
      this.channel = transport.channel;
      return transport.joined;
    }

    stop() {
      if (!this.recording) return;
      this.finishing = true;
      this.recording = false;
      this.setStatus("Finishing transcription…");
      this.disposeCapture();
      this.channel?.push("stop", {});
      this.clearFinishTimer();
      this.finishTimer = window.setTimeout(() => {
        const channel = this.channel;
        if (channel) this.handleTransportFailure("Speech-to-text final transcript timed out. Try dictation again.", this.generation, channel);
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
      if (payload.kind === "final" && this.captureMode !== "conversation") this.setStatus("Dictation ready. Review the text, then press Send.");
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

    explainFailure(error) {
      if (error?.name === "NotAllowedError" || error?.name === "SecurityError") {
        this.setStatus("Microphone permission was denied for this origin. Allow it in site settings, then try again.");
      } else if (error?.name === "NotFoundError") {
        this.setStatus("No microphone is available. Connect one or choose a different browser microphone.");
      } else {
        this.setStatus(error?.message || "Microphone dictation could not start.");
      }
    }

    handleTransportFailure(message, generation, channel) {
      if (!this.current(generation) || this.channel !== channel) return;
      this.clearFinishTimer();
      this.finishing = false;
      this.resetConversationState();
      this.setStatus(message);
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

    setStatus(message) {
      this.statusMessage = message;
      if (this.status) this.status.textContent = message;
    }

    disposeCapture() {
      this.capture?.stop();
      this.capture = null;
      this.recording = false;
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
      this.mic?.removeEventListener("click", this.onMicClick);
      this.conversation?.removeEventListener("click", this.onConversationClick);
      this.device?.removeEventListener("change", this.onDeviceChange);
      this.disposeCapture();
      this.closeChannel();
      this.playbackContext?.close();
    }
  }

  window.AiurConversationVoiceController = ConversationVoiceController;
})();
