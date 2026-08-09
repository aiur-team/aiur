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

  const DomSvgLayout = window.AiurDomSvgLayout?.createLiveViewHook
    ? window.AiurDomSvgLayout.createLiveViewHook(() => {
        if (typeof window.__aiurBrowserLayoutHookOptions === "function") {
          return window.__aiurBrowserLayoutHookOptions();
        }

        return typeof window.__aiurBrowserLayoutClientFactory === "function"
          ? { clientFactory: window.__aiurBrowserLayoutClientFactory }
          : {};
      })
    : {
        mounted() {
          this.el.classList.remove("is-layout-ready");
          this.el.classList.add("is-layout-fallback");
          this.el.dataset.layoutHealth = "fallback";
        }
      };

  window.BrowserHarnessHooks = { BrowserHarness, DomSvgLayout };
})();
