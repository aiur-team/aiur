(() => {
  window.AiurTicketContextDialogHook = {
    mounted() {
      this.closeEvent = this.el.dataset.closeEvent;
      this.fallbackFocusId = this.el.dataset.focusFallbackId;
      this.origin = document.activeElement instanceof HTMLElement ? document.activeElement : null;
      this.onKeydown = this.handleKeydown.bind(this);
      this.el.addEventListener("keydown", this.onKeydown);

      requestAnimationFrame(() => {
        const heading = this.el.querySelector("[data-dialog-heading]");
        (heading || this.el).focus();
      });
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKeydown);

      requestAnimationFrame(() => {
        const origin = this.origin;
        const fallback = this.fallbackFocusId ? document.getElementById(this.fallbackFocusId) : null;

        if (
          origin?.isConnected &&
          origin !== document.body &&
          origin !== document.documentElement &&
          !origin.hasAttribute("disabled") &&
          origin.getAttribute("aria-disabled") !== "true"
        ) {
          origin.focus();
        } else {
          fallback?.focus();
        }
      });
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
    }
  };
})();
