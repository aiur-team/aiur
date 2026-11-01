(() => {
  window.AiurConversationDrawerHook = {
    mounted() {
      this.threshold = 24;
      this.readDataset();
      this.origin = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      this.onKeydown = this.handleKeydown.bind(this);
      this.onScroll = this.updateJump.bind(this);
      this.onViewportResize = this.handleViewportResize.bind(this);
      this.onComposerInput = this.resizeComposer.bind(this);
      this.onJumpClick = () => {
        this.scrollToBottom();
        this.updateJump();
      };

      this.el.addEventListener("keydown", this.onKeydown);
      window.visualViewport?.addEventListener("resize", this.onViewportResize);
      window.visualViewport?.addEventListener("scroll", this.onViewportResize);
      this.bindScrollElements();
      this.bindComposer();
      this.onDrawerFocusIn = (event) => {
        if (event.target?.matches?.("[data-chat-composer]")) {
          this.syncComposerFocus();
          this.handleViewportResize();
        }
      };
      this.onDrawerFocusOut = (event) => {
        if (event.target?.matches?.("[data-chat-composer]") && !this.el.querySelector(".agent-chat-composer")?.contains(event.relatedTarget)) {
          this.el.classList.remove("is-chat-composer-focused");
        }
      };
      this.el.addEventListener("focusin", this.onDrawerFocusIn);
      this.el.addEventListener("focusout", this.onDrawerFocusOut);
      this.voice = new window.AiurConversationVoiceController(this);
      this.voice.mount();
      this.executorVoice = new window.AiurExecutorVoiceController(this.el);
      this.executorVoice.bindElements();
      this.focusHeading();

      requestAnimationFrame(() => {
        this.scrollToBottom();
        this.resizeComposer();
        this.handleViewportResize();
        this.updateJump();
      });
    },
    beforeUpdate() {
      this.wasAtBottom = this.isAtBottom();
      const active = document.activeElement;
      this.activeFocusKey = this.el.contains(active) ? active.dataset.conversationFocus : undefined;
    },
    updated() {
      this.readDataset();
      this.bindScrollElements();
      this.bindComposer();
      this.syncComposerFocus();
      this.voice.bindElements();
      this.executorVoice.bindElements();

      if (this.wasAtBottom) this.scrollToBottom();
      this.updateJump();
      this.wasAtBottom = undefined;
      this.restoreActiveFocus();
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKeydown);
      this.el.removeEventListener("focusin", this.onDrawerFocusIn);
      this.el.removeEventListener("focusout", this.onDrawerFocusOut);
      window.visualViewport?.removeEventListener("resize", this.onViewportResize);
      window.visualViewport?.removeEventListener("scroll", this.onViewportResize);
      this.unbindScrollElements();
      this.unbindComposer();
      this.voice.destroy();
      this.executorVoice.destroy();
      if (this.viewportFrame !== undefined) cancelAnimationFrame(this.viewportFrame);
      this.viewportFrame = undefined;

      requestAnimationFrame(() => {
        const explicitOrigin = this.originId ? document.getElementById(this.originId) : null;
        const fallback = this.fallbackFocusId ? document.getElementById(this.fallbackFocusId) : null;
        const target = [explicitOrigin, this.origin, fallback].find((element) => this.restorable(element));
        target?.focus();
      });
    },
    readDataset() {
      this.closeEvent = this.el.dataset.closeEvent;
      this.fallbackFocusId = this.el.dataset.focusFallbackId;
      this.originId = this.el.dataset.originId;
    },
    bindScrollElements() {
      const scroll = this.el.querySelector("[data-conversation-scroll]");
      const jump = this.el.querySelector("[data-conversation-jump]");

      if (scroll !== this.scroll) {
        this.scroll?.removeEventListener("scroll", this.onScroll);
        this.scroll = scroll;
        this.scroll?.addEventListener("scroll", this.onScroll);
      }

      if (jump !== this.jump) {
        this.jump?.removeEventListener("click", this.onJumpClick);
        this.jump = jump;
        this.jump?.addEventListener("click", this.onJumpClick);
      }
    },
    bindComposer() {
      const composer = this.el.querySelector("[data-chat-composer]");
      if (composer === this.composer) return;
      this.unbindComposer();
      this.composer = composer;
      this.composer?.addEventListener("input", this.onComposerInput);
      this.resizeComposer();
    },
    unbindComposer() {
      this.composer?.removeEventListener("input", this.onComposerInput);
      this.composer = null;
    },
    resizeComposer() {
      if (!this.composer) return;
      this.composer.style.height = "auto";
      const styles = getComputedStyle(this.composer);
      const maxHeight = parseFloat(styles.maxHeight) || 140;
      this.composer.style.height = `${Math.min(this.composer.scrollHeight, maxHeight)}px`;
      this.composer.style.overflowY = this.composer.scrollHeight > maxHeight ? "auto" : "hidden";
      this.handleViewportResize();
    },
    handleViewportResize() {
      const viewport = window.visualViewport;
      if (viewport) {
        this.el.style.setProperty("--conversation-viewport-height", `${viewport.height}px`);
        this.el.style.setProperty("--conversation-viewport-offset-top", `${viewport.offsetTop}px`);
      }
      if (this.following ?? this.isAtBottom()) {
        this.following = true;
        if (this.viewportFrame !== undefined) return;
        this.viewportFrame = requestAnimationFrame(() => {
          this.viewportFrame = undefined;
          if (!this.el.isConnected || !this.following) return;
          this.scrollToBottom();
          this.updateJump();
        });
      }
    },
    unbindScrollElements() {
      this.scroll?.removeEventListener("scroll", this.onScroll);
      this.jump?.removeEventListener("click", this.onJumpClick);
    },
    handleKeydown(event) {
      if (event.key === "Escape" && this.closeEvent) {
        event.preventDefault();
        this.pushEvent(this.closeEvent, {});
        return;
      }

      if (event.key !== "Tab") return;

      const focusable = this.focusable();
      if (focusable.length === 0) {
        event.preventDefault();
        this.el.querySelector("[data-dialog-heading]")?.focus();
        return;
      }

      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      const active = document.activeElement;
      const heading = this.el.querySelector("[data-dialog-heading]");

      if (event.shiftKey && (active === first || active === heading)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && active === last) {
        event.preventDefault();
        first.focus();
      }
    },
    focusable() {
      return Array.from(this.el.querySelectorAll(
        "summary, a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
      )).filter((element) => !element.closest("[hidden]") && element.getClientRects().length > 0 && element.getAttribute("aria-hidden") !== "true");
    },
    focusHeading() {
      requestAnimationFrame(() => {
        if (!this.el.isConnected) return;

        const heading = this.el.querySelector("[data-dialog-heading]");
        (heading || this.el).focus();
      });
    },
    syncComposerFocus() {
      const composer = this.el.querySelector("[data-chat-composer]");
      this.el.classList.toggle("is-chat-composer-focused", composer === document.activeElement);
    },
    restoreActiveFocus() {
      const focusKey = this.activeFocusKey;
      this.activeFocusKey = undefined;
      if (!focusKey) return;

      requestAnimationFrame(() => {
        if (!this.el.isConnected) return;

        const candidate = Array.from(this.el.querySelectorAll("[data-conversation-focus]"))
          .find((element) => element.dataset.conversationFocus === focusKey);
        (candidate || this.el.querySelector("[data-dialog-heading]") || this.el).focus();
      });
    },
    isAtBottom() {
      if (!this.scroll) return true;
      return this.scroll.scrollHeight - this.scroll.scrollTop - this.scroll.clientHeight <= this.threshold;
    },
    scrollToBottom() {
      if (this.scroll) this.scroll.scrollTop = this.scroll.scrollHeight;
    },
    updateJump() {
      if (!this.scroll) return;

      const atBottom = this.isAtBottom();
      this.following = atBottom;
      this.scroll.dataset.live = atBottom ? "true" : "false";

      if (!this.jump) return;
      const scrollable = this.scroll.scrollHeight - this.scroll.clientHeight > this.threshold;
      this.jump.hidden = !(scrollable && !atBottom);
    },
    restorable(element) {
      return element instanceof HTMLElement &&
        element.isConnected &&
        element !== document.body &&
        element !== document.documentElement &&
        !element.hasAttribute("disabled") &&
        element.getAttribute("aria-disabled") !== "true";
    }
  };
})();
