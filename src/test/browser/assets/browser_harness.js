(() => {
  const BrowserHarness = {
    mounted() {
      this.el.dataset.liveStatus = "connected";
      this.pushEvent("reduced-motion", {
        reduced: window.matchMedia("(prefers-reduced-motion: reduce)").matches
      });
      this.el.textContent = "Worker starting";
      this.worker = new Worker("/assets/browser_worker.js");
      this.worker.addEventListener("message", ({ data }) => {
        if (data.kind !== "ready") return;

        this.el.dataset.workerReady = "true";
        this.el.textContent = "Worker ready";
        this.pushEvent("worker-ready", {});
      });
    },
    disconnected() {
      this.el.dataset.liveStatus = "disconnected";
    },
    reconnected() {
      this.el.dataset.liveStatus = "reconnected";
    },
    destroyed() {
      this.worker?.terminate();
    }
  };

  window.BrowserHarnessHooks = { BrowserHarness };
})();
