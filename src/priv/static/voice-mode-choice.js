(() => {
  // Explicit mode selection owns no capture: only Dictate delegates to it.
  class VoiceModeChoice {
    constructor(controller) {
      this.controller = controller;
      this.el = controller.hook.el;
      this.onClick = (event) => this.click(event);
      this.onKey = (event) => this.keydown(event);
      this.onOutside = (event) => {
        if (this.open && !event.target.closest(".agent-voice-choice")) this.close(false);
      };
      document.addEventListener("click", this.onOutside);
      this.el.addEventListener("click", this.onClick);
      this.el.addEventListener("keydown", this.onKey, true);
    }

    bind() {
      this.root = this.el.querySelector("[data-voice-root]");
      this.trigger = this.root?.querySelector("[data-voice-chooser]");
      this.menu = this.root?.querySelector("[data-voice-menu]");
      if (this.trigger && this.menu) {
        this.trigger.setAttribute("aria-expanded", String(Boolean(this.open)));
        this.menu.hidden = !this.open;
      }
    }

    sync() {
      if (!this.trigger) return;
      const c = this.controller;
      if (this.open && (c.starting || c.recording || c.finishing)) this.close(false);
      this.trigger.disabled = Boolean(c.starting || c.finishing || c.awaitingReply || c.speaking || (c.recording && c.captureMode !== "dictation"));
      this.trigger.setAttribute("aria-label", c.recording ? "Stop dictation" : "Choose voice input");
      this.trigger.setAttribute("aria-pressed", c.recording ? "true" : "false");
    }

    close(restoreFocus = true) {
      if (!this.trigger) return;
      this.open = false;
      this.trigger.setAttribute("aria-expanded", "false");
      this.menu.hidden = true;
      if (restoreFocus) this.trigger.focus();
    }

    click(event) {
      if (event.target.closest("[data-voice-chooser]")) {
        if (this.controller.recording) return this.controller.stop();
        const open = this.trigger.getAttribute("aria-expanded") !== "true";
        this.open = open;
        this.trigger.setAttribute("aria-expanded", String(open));
        this.menu.hidden = !open;
        if (open) this.menu.querySelector("[data-voice-mode]")?.focus();
        return;
      }
      const mode = event.target.closest("[data-voice-mode]");
      if (!mode || mode.getAttribute("aria-disabled") === "true" || mode.disabled) return;
      this.close();
      if (mode.dataset.voiceMode === "dictate") this.controller.toggle("dictation");
      // The panel consumer is owned by C3-T02; this event never captures audio.
      if (mode.dataset.voiceMode === "converse") {
        const { surface, target } = this.context();
        this.controller.hook.pushEvent("open-voice-conversation", { surface, target: JSON.stringify(target) });
      }
    }

    keydown(event) {
      if (!this.trigger || this.menu.hidden) return;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopImmediatePropagation();
        this.close();
      }
      if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const items = Array.from(this.menu.querySelectorAll("[data-voice-mode]"));
      const index = items.indexOf(document.activeElement);
      const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 :
        (index + (event.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      items[next]?.focus();
    }

    context() {
      return { surface: this.root.dataset.voiceSurface, target: JSON.parse(this.root.dataset.voiceTarget) };
    }

    joinPayload() {
      return { v: 1, mode: "dictate", ...this.context(), client_session_id: crypto.randomUUID() };
    }

    destroy() {
      document.removeEventListener("click", this.onOutside);
      this.el.removeEventListener("click", this.onClick);
      this.el.removeEventListener("keydown", this.onKey, true);
    }
  }
  window.AiurVoiceModeChoice = VoiceModeChoice;
})();
