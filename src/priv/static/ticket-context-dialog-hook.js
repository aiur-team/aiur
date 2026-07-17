(() => {
  window.AiurTicketContextDialogHook = {
    mounted() {
      this.closeEvent = this.el.dataset.closeEvent;
      this.focusKey = this.el.dataset.focusKey;
      this.originId = this.el.dataset.originId;
      this.onKeydown = this.handleKeydown.bind(this);
      this.el.addEventListener("keydown", this.onKeydown);
      this.focusHeading();
    },
    beforeUpdate() {
      const active = document.activeElement;
      this.activeFocusKey = this.el.contains(active) ? active.dataset.ticketContextFocus : undefined;
    },
    updated() {
      this.closeEvent = this.el.dataset.closeEvent;
      this.originId = this.el.dataset.originId;

      const nextFocusKey = this.el.dataset.focusKey;
      if (nextFocusKey && nextFocusKey !== this.focusKey) {
        this.focusKey = nextFocusKey;
        this.activeFocusKey = undefined;
        this.focusHeading();
      } else {
        this.restoreActiveFocus();
      }
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKeydown);

      const originId = this.originId;
      if (originId) {
        requestAnimationFrame(() => document.getElementById(originId)?.focus());
      }
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
      )).filter((element) => !element.hasAttribute("hidden") && element.getAttribute("aria-hidden") !== "true");
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

        const candidate = Array.from(this.el.querySelectorAll("[data-ticket-context-focus]"))
          .find((element) => element.dataset.ticketContextFocus === focusKey);
        candidate?.focus();
      });
    }
  };
})();
