window.AiurNavToggleHook = {
  mounted: function () {
    this.root = document.documentElement;
    this.media = window.matchMedia("(min-width: 961px)");
    this.onMedia = () => this.mirror();
    this.media.addEventListener("change", this.onMedia);
    this.nav = document.getElementById("ax-nav");
    this.onNavFocus = (e) => { if (!this.media.matches && e.target.matches("a.snav")) e.target.scrollIntoView({block: "nearest", inline: "nearest"}); };
    this.nav?.addEventListener("focusin", this.onNavFocus);
    this.onKey = (e) => {
      if (!["Enter", " ", "ArrowLeft", "ArrowRight"].includes(e.key)) return;
      e.preventDefault();
      this.commit(e.key === "ArrowLeft" || (e.key !== "ArrowRight" && !this.root.classList.contains("nav-collapsed")));
    };
    this.onDown = (e) => {
      if (e.button !== 0 || !this.media.matches) return;
      e.preventDefault();
      this.drag = {id: e.pointerId, x: e.clientX, width: this.root.classList.contains("nav-collapsed") ? 60 : 188};
      this.el.setPointerCapture(e.pointerId);
      this.root.classList.add("nav-drag");
    };
    this.onMove = (e) => {
      if (!this.drag || e.pointerId !== this.drag.id) return;
      var width = Math.max(50, Math.min(204, this.drag.width + e.clientX - this.drag.x));
      this.root.style.setProperty("--navw", width + "px");
      this.root.classList.toggle("nav-collapsed", width < 124);
    };
    this.onUp = (e) => {
      if (!this.drag || e.pointerId !== this.drag.id) return;
      var width = parseFloat(this.root.style.getPropertyValue("--navw")) || this.drag.width;
      var collapsed = Math.abs(e.clientX - this.drag.x) > 3 ? width < 124 : !this.root.classList.contains("nav-collapsed");
      this.cleanDrag();
      void this.root.offsetWidth;
      this.commit(collapsed);
    };
    this.onCancel = () => { if (this.drag) { this.cleanDrag(); this.mirror(); } };
    this.el.addEventListener("keydown", this.onKey);
    this.el.addEventListener("pointerdown", this.onDown);
    this.el.addEventListener("pointermove", this.onMove);
    this.el.addEventListener("pointerup", this.onUp);
    this.el.addEventListener("pointercancel", this.onCancel);
    this.el.addEventListener("lostpointercapture", this.onCancel);
    import("/aiur-style/js/storage.js").then((storage) => {
      if (!this.el.isConnected) return;
      this.navStorage = storage;
      const stored = storage.readStorage("aiur-nav-collapsed");
      if ((stored === "true" || stored === "false") && (stored === "true") !== this.collapsed()) {
        this.pending = stored === "true";
        this.pushEvent("restore-nav", {collapsed: this.pending}, () => {});
      } else this.mirror();
    });
  },
  // A push made before reconnect is lost, so the server state wins again.
  reconnected: function () { this.pending = undefined; this.mirror(); },
  collapsed: function () { return this.el.dataset.navCollapsed === "true"; },
  mirror: function () {
    // An unacknowledged choice outranks server state it has not reached yet.
    var collapsed = this.pending === undefined ? this.collapsed() : this.pending;
    if (!this.drag) this.root.classList.toggle("nav-collapsed", this.media.matches && collapsed);
  },
  updated: function () {
    if (this.pending !== undefined && this.collapsed() !== this.pending) return;
    this.pending = undefined;
    this.mirror();
    this.navStorage?.writeStorage("aiur-nav-collapsed", String(this.collapsed()));
  },
  commit: function (collapsed) {
    this.pending = collapsed;
    this.root.classList.toggle("nav-collapsed", this.media.matches && collapsed);
    this.pushEvent("restore-nav", {collapsed: collapsed}, () => {});
    clearTimeout(this.resizeTimer);
    this.resizeTimer = setTimeout(() => window.dispatchEvent(new Event("resize")), 260);
  },
  cleanDrag: function () {
    var drag = this.drag;
    this.drag = null;
    this.root.classList.remove("nav-drag");
    this.root.style.removeProperty("--navw");
    if (drag && this.el.hasPointerCapture(drag.id)) this.el.releasePointerCapture(drag.id);
  },
  destroyed: function () {
    this.cleanDrag();
    clearTimeout(this.resizeTimer);
    this.media.removeEventListener("change", this.onMedia);
    this.nav?.removeEventListener("focusin", this.onNavFocus);
    this.el.removeEventListener("keydown", this.onKey);
    this.el.removeEventListener("pointerdown", this.onDown);
    this.el.removeEventListener("pointermove", this.onMove);
    this.el.removeEventListener("pointerup", this.onUp);
    this.el.removeEventListener("pointercancel", this.onCancel);
    this.el.removeEventListener("lostpointercapture", this.onCancel);
  }
};
