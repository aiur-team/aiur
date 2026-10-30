(() => {
  window.AiurVoiceInputHook = {
    mounted() {
      this.voice = new window.AiurConversationVoiceController(this);
      this.voice.mount();
    },
    updated() {
      this.voice.serverUpdated();
      this.voice.bindElements();
      this.resolveVoiceInput?.();
    },
    prepareVoiceInput() {
      const name = this.el.dataset.voiceSelectCustom;
      if (!name) return Promise.resolve();
      const field = () => this.el.querySelector("[data-voice-input]:not(:disabled)");
      const choice = Array.from(this.el.querySelectorAll("input")).find((input) => input.name === name && input.value === "custom");
      if (!choice || choice.disabled) return Promise.reject(new Error("The response field did not open."));
      if (choice.checked || choice.type === "hidden") {
        return field() ? Promise.resolve() : Promise.reject(new Error("The response field did not open."));
      }
      return new Promise((resolve, reject) => {
        const timer = window.setTimeout(() => {
          this.resolveVoiceInput = null;
          reject(new Error("The response field did not open."));
        }, 2000);
        this.resolveVoiceInput = () => {
          if (!field()) return;
          window.clearTimeout(timer);
          this.resolveVoiceInput = null;
          resolve();
        };
        choice.checked = true;
        choice.dispatchEvent(new Event("change", { bubbles: true }));
      });
    },
    destroyed() { this.voice.destroy(); }
  };

  // Preserve local dictation through stale server patches until the server has
  // rendered the same value. An intentional server normalization/reset does not
  // count as an ack; the hold remains until the input is reinitialized.
  window.AiurVoiceInputBeforeUpdate = (from, to) => {
    if (from.matches("textarea[data-voice-input][data-voice-recording='true']")) {
      const synced = from.value === to.value;
      to.value = from.value;
      if (synced) delete to.dataset.voiceRecording;
      else to.dataset.voiceRecording = "true";
    }
  };
})();
