// Mount the retained prototype outside the worker drawer.
(() => {
  window.AiurExecutorVoiceHook = {
    mounted() {
      this.executorVoice = new window.AiurExecutorVoiceController(this.el);
      this.executorVoice.bindElements();
    },
    updated() {
      this.executorVoice.bindElements();
    },
    destroyed() {
      this.executorVoice.destroy();
    },
  };
})();
