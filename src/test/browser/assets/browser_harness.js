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

  const DomSvgLayout = {
    mounted() {
      const context = this;
      context.__domSvgLayoutDestroyed = false;

      import("/aiur-dom-svg-layout-adapter.js")
        .then((adapter) => {
          if (context.__domSvgLayoutDestroyed) return;

          const options = typeof window.__aiurBrowserLayoutClientFactory === "function"
            ? { clientFactory: window.__aiurBrowserLayoutClientFactory }
            : {};

          context.__domSvgLayoutHook = adapter.createDomSvgLayoutHook(options);
          context.__domSvgLayoutHook.mounted.call(context);
        })
        .catch(() => {
          context.el.classList.remove("is-layout-ready");
          context.el.classList.add("is-layout-fallback");
          context.el.dataset.layoutHealth = "fallback";
        });
    },
    beforeUpdate() {
      this.__domSvgLayoutHook?.beforeUpdate.call(this);
    },
    updated() {
      this.__domSvgLayoutHook?.updated.call(this);
    },
    destroyed() {
      this.__domSvgLayoutDestroyed = true;
      this.__domSvgLayoutHook?.destroyed.call(this);
      this.__domSvgLayoutHook = null;
    }
  };

  window.BrowserHarnessHooks = { BrowserHarness, DomSvgLayout };
})();
