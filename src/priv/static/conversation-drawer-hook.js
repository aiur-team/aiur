(() => {
  window.AiurConversationDrawerHook = {
    mounted() {
      this.threshold = 24;
      this.readDataset();
      this.origin = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      this.onKeydown = this.handleKeydown.bind(this);
      this.onScroll = this.updateJump.bind(this);
      this.onJumpClick = () => {
        this.scrollToBottom();
        this.updateJump();
      };

      this.el.addEventListener("keydown", this.onKeydown);
      this.bindScrollElements();
      this.focusHeading();

      requestAnimationFrame(() => {
        this.scrollToBottom();
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

      if (this.wasAtBottom) this.scrollToBottom();
      this.updateJump();
      this.restoreActiveFocus();
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKeydown);
      this.unbindScrollElements();

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
        "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])"
      )).filter((element) => !element.hidden && !element.hasAttribute("hidden") && element.getAttribute("aria-hidden") !== "true");
    },
    focusHeading() {
      requestAnimationFrame(() => {
        if (!this.el.isConnected) return;

        const heading = this.el.querySelector("[data-dialog-heading]");
        (heading || this.el).focus();
      });
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
