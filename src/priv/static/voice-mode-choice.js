(() => {
  // Explicit mode selection owns no capture: only Dictate delegates to it.
  class VoiceModeChoice {
    constructor(controller) {
      this.controller = controller;
      this.el = controller.hook.el;
      this.onClick = (event) => this.click(event);
      this.onEdit = (event) => {
        if (controller.state === "ready" && (event.type === "submit" || event.target.matches("[data-voice-input]"))) controller.transition("idle");
      };
      this.el.addEventListener("input", this.onEdit);
      this.el.addEventListener("submit", this.onEdit);
      this.onKey = (event) => this.keydown(event);
      this.onOutside = (event) => {
        if (this.open && !event.target.closest(".agent-voice-choice")) this.close(false);
      };
      document.addEventListener("click", this.onOutside);
      this.el.addEventListener("click", this.onClick);
      this.el.addEventListener("keydown", this.onKey, true);
    }

    bind() {
      this.root = this.el.matches("[data-voice-root]") ? this.el : this.el.querySelector("[data-voice-root]");
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
      if (event.target.closest("[data-voice-cancel]")) return this.controller.cancel();
      if (event.target.closest("[data-voice-chooser]")) {
        if (this.controller.recording) return this.controller.stop();
        window.AiurVoiceInputState.availability(this.controller);
        const open = this.trigger.getAttribute("aria-expanded") !== "true";
        this.open = open;
        this.trigger.setAttribute("aria-expanded", String(open));
        this.menu.hidden = !open;
        if (open) this.menu.querySelector("[data-voice-mode]")?.focus();
        return;
      }
      const mode = event.target.closest("[data-voice-mode]");
      if (!mode || mode.getAttribute("aria-disabled") === "true" || mode.disabled) return;
      const c = this.controller;
      if (mode.dataset.voiceMode === "converse" && (c.starting || c.recording || c.finishing || c.awaitingReply || c.speaking)) return;
      this.close();
      if (mode.dataset.voiceMode === "dictate") this.controller.toggle("dictation");
      // The panel consumer is owned by C3-T02; this event never captures audio.
      if (mode.dataset.voiceMode === "converse") {
        const { surface, target } = this.context();
        this.controller.hook.pushEvent("open-voice-conversation", { surface, target: JSON.stringify(target) });
      }
    }

    keydown(event) {
      const c = this.controller;
      if (event.key === "Escape" && (c.recording || c.finishing) &&
          (this.root?.contains(event.target) || event.target === c.input)) {
        event.preventDefault();
        event.stopPropagation();
        c.cancel();
        return;
      }
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
      this.el.removeEventListener("input", this.onEdit);
      this.el.removeEventListener("submit", this.onEdit);
      document.removeEventListener("click", this.onOutside);
      this.el.removeEventListener("click", this.onClick);
      this.el.removeEventListener("keydown", this.onKey, true);
    }
  }
  window.AiurVoiceModeChoice = VoiceModeChoice;
})();

(() => {
  // One copy table for channel refusals and failures. Unknown causes stay neutral.
  const reasons = {
    unconfigured: "Voice input is not configured.",
    not_installed: "Voice input isn't installed in this Aiur. Typed messages work as usual.",
    read_only: "Dashboard writing is disabled.",
    auth_changed: "Dashboard authentication changed. Reload and sign in again.",
    capacity: "Too many dashboard dictation sessions are active. Close another microphone and retry.",
    target_not_found: { worker: "Agent is no longer running.", command: "This Command no longer exists." },
    target_not_writable: "Agent actions require a unique typed target.",
    target_stale: "This Command has changed. Reload it before dictating an answer.",
    provider_auth: "ElevenLabs rejected the API key",
    provider_quota: "ElevenLabs quota exhausted",
    provider_unavailable: "Speech-to-text is unavailable right now.",
    chunk_too_large: "Audio chunk is too large.",
    session_limit: "Dictation reached the five-minute limit. Review the text and start again.",
    permission_denied: "Microphone permission was denied for this origin. Allow it in site settings, then try again.",
    no_device: "No microphone is available. Connect one or choose a different browser microphone.",
    transport_lost: "Speech-to-text connection was lost. Try dictation again.",
    privacy_preflight_failed: "Microphone dictation could not start.",
    unsupported_target: "Voice input can't address this target yet.",
    invalid_payload: "Voice request is invalid.",
    cost_cap: "Microphone dictation could not start.",
    ticket_used: "Microphone dictation could not start.",
    provider_error: "Speech-to-text failed.",
    unknown: "Microphone dictation could not start."
  };
  const states = {
    idle: "Press the microphone to dictate. Review the text, then press Send.",
    requesting_permission: "Requesting microphone permission…",
    listening: "Listening… press the microphone again when you are finished.",
    finishing: "Finishing transcription…",
    ready: "Dictation ready. Review the text, then press Send.",
    cancelled: "Press the microphone to dictate. Review the text, then press Send."
  };

  function transition(controller, next, detail = {}) {
    detail ||= {};
    controller.state = next;
    const code = Object.hasOwn(reasons, detail.reason_code) ? detail.reason_code : "unknown";
    controller.reasonCode = detail.reason_code ? code : null;
    const copy = code === "target_not_found" ? reasons[code][controller.choice.context().target.kind] || reasons.unknown : reasons[code];
    const message = (["unavailable", "listening", "ready"].includes(next) || detail.local) && detail.message ? detail.message :
      (next === "idle" && controller.idleCopy) || states[next] || copy;
    controller.setStatus(message, ["unavailable", "permission_denied", "no_device", "error"].includes(next));
    controller.syncElements();
  }

  function availability(controller) {
    // An active session remains server-authoritative across capability patches.
    if (controller.starting || controller.recording || controller.finishing || controller.conversationActive) return;
    const root = controller.choice.root;
    if (!root) return;
    const available = ["available", "degraded"].includes(root?.dataset.voiceSttState);
    if (available && root.dataset.voiceState === "idle") controller.idleCopy = controller.status?.textContent?.trim() || states.idle;
    controller.unavailableReason = controller.browserUnavailable || (!available && (
      root?.querySelector("[data-voice-mode='dictate'] span")?.textContent || "Voice input availability is unknown."
    ));
    if (controller.unavailableReason) {
      controller.transition("unavailable", { message: controller.unavailableReason });
    } else if (!controller.state || controller.state === "unavailable") {
      controller.transition("idle");
    }
  }

  function failure(controller, error, preparingField = false) {
    if (preparingField) return controller.transition("error", { message: "The response field did not open.", local: true });
    const code = ["NotAllowedError", "SecurityError"].includes(error?.name) ? "permission_denied" :
      error?.name === "NotFoundError" ? "no_device" : error?.reason_code || "unknown";
    controller.transition(["permission_denied", "no_device"].includes(code) ? code : "error", { reason_code: code });
  }

  window.AiurVoiceInputState = { transition, availability, failure };
})();
