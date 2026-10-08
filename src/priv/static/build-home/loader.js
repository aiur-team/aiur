(() => {
  const MODULE_URL = "/build-home/hook.js";
  const CALLBACKS = ["beforeUpdate", "updated", "disconnected", "reconnected"];
  const fail = (el) => { el.dataset.buildHomeHook = "failed"; };

  function createLiveViewHook() {
    const hook = {
      mounted() {
        const ctx = this;
        ctx.__buildHomeDestroyed = false;
        ctx.el.dataset.buildHomeHook = "loading";
        import(MODULE_URL)
          .then((module) => {
            if (ctx.__buildHomeDestroyed) return;
            if (typeof module.createBuildHomeHook !== "function") return fail(ctx.el);
            ctx.__buildHome = module.createBuildHomeHook();
            ctx.__buildHome.mounted?.call(ctx);
          })
          .catch(() => { if (!ctx.__buildHomeDestroyed) fail(ctx.el); });
      },
      destroyed() {
        this.__buildHomeDestroyed = true;
        this.__buildHome?.destroyed?.call(this);
        this.__buildHome = null;
      }
    };
    for (const name of CALLBACKS) {
      hook[name] = function () { this.__buildHome?.[name]?.call(this); };
    }
    return hook;
  }

  window.AiurBuildHome = { createLiveViewHook };
})();
