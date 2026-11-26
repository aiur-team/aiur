(() => {
  window.AiurVoicePlayback = {
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
    },

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
    },

    clearPlaybackTimer() {
      if (this.playbackTimer) window.clearTimeout(this.playbackTimer);
      this.playbackTimer = null;
    },

    clearPlaybackSources(stop = true) {
      for (const source of this.playbackSources || []) {
        if (stop) {
          try { source.stop(); } catch (_error) {}
        }
        source.disconnect?.();
      }
      this.playbackSources?.clear();
    }
  };
})();
