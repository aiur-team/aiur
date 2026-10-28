(() => {
  window.AiurVoiceInputHook = {
    mounted() {
      this.voice = new window.AiurConversationVoiceController(this);
      this.voice.mount();
    },
    updated() { this.voice.bindElements(); },
    destroyed() { this.voice.destroy(); }
  };

  // Preserve local dictation through repeated stale server patches. Once
  // capture stops, the controller removes the marker and server values win.
  window.AiurVoiceInputBeforeUpdate = (from, to) => {
    if (from.matches("textarea[data-voice-input][data-voice-recording='true']")) {
      to.value = from.value;
      to.dataset.voiceRecording = "true";
    }
  };
})();
