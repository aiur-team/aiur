defmodule AiurWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:page_title, page_title())

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark" data-palette="gruvbox">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <link rel="icon" type="image/png" href="/aiur-logo.png" />
        <link rel="apple-touch-icon" href="/aiur-logo.png" />
        <title>{@page_title}</title>
        <script>
          (function () {
            try { if (window.localStorage.getItem("aiur-nav-collapsed") === "true" && window.matchMedia("(min-width: 961px)").matches) document.documentElement.classList.add("nav-collapsed"); } catch (_error) {}
            var theme;
            try { theme = window.localStorage.getItem("aiur-theme"); } catch (_error) {}
            document.documentElement.dataset.theme = theme === "light" || theme === "dark"
              ? theme : (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
            try {
              if (window.localStorage.getItem("aiur-palette") === "aiur") {
                document.documentElement.dataset.palette = "aiur";
              }
            } catch (_error) {}
          })();
        </script>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script defer src="/aiur-dom-svg-layout-loader.js"></script>
        <script defer src="/ticket-context-dialog-hook.js"></script>
        <script defer src="/conversation-voice-controller.js"></script>
        <script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/build-order-grid-hook.js"></script>
        <script defer src="/time-brush-hook.js"></script>
        <script defer src="/streamdeck-emulator-hook.js"></script>
        <script defer src="/sortable-table-hook.js"></script>
        <script defer src="/build-home/loader.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var Hooks = {};

            Hooks.AgentLogPanel = {
              mounted: function () {
                this.threshold = 24;
                this.liveButton = this.el
                  .closest(".modal-panel")
                  ?.querySelector("[data-agent-log-live]");

                this.onScroll = this.updateLiveButton.bind(this);
                this.onLiveClick = () => {
                  this.scrollToBottom();
                  this.updateLiveButton();
                };

                this.el.addEventListener("scroll", this.onScroll);
                this.liveButton?.addEventListener("click", this.onLiveClick);

                requestAnimationFrame(() => {
                  this.scrollToBottom();
                  this.updateLiveButton();
                });
              },
              beforeUpdate: function () {
                this.wasAtBottom = this.isAtBottom();
              },
              updated: function () {
                if (this.wasAtBottom) this.scrollToBottom();
                this.updateLiveButton();
              },
              destroyed: function () {
                this.el.removeEventListener("scroll", this.onScroll);
                this.liveButton?.removeEventListener("click", this.onLiveClick);
              },
              isAtBottom: function () {
                return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight <= this.threshold;
              },
              scrollToBottom: function () {
                this.el.scrollTop = this.el.scrollHeight;
              },
              updateLiveButton: function () {
                var live = this.isAtBottom();
                if (!this.liveButton) return;

                this.liveButton.dataset.live = live ? "true" : "false";
                this.liveButton.setAttribute("aria-pressed", live ? "true" : "false");
              }
            };

            Hooks.NavToggle = {
              mounted: function () {
                this.root = document.documentElement;
                this.media = window.matchMedia("(min-width: 961px)");
                this.onMedia = () => this.mirror();
                this.media.addEventListener("change", this.onMedia);
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
                var stored;
                try { stored = window.localStorage.getItem("aiur-nav-collapsed"); } catch (_error) {}
                if ((stored === "true" || stored === "false") && (stored === "true") !== this.collapsed()) {
                  this.pending = stored === "true";
                  this.pushEvent("restore-nav", {collapsed: this.pending}, () => {});
                } else this.mirror();
              },
              reconnected: function () { this.mirror(); },
              collapsed: function () { return this.el.dataset.navCollapsed === "true"; },
              mirror: function () {
                if (!this.drag) this.root.classList.toggle("nav-collapsed", this.media.matches && this.collapsed());
              },
              updated: function () {
                if (this.pending !== undefined && this.collapsed() !== this.pending) return;
                this.pending = undefined;
                this.mirror();
                try { window.localStorage.setItem("aiur-nav-collapsed", String(this.collapsed())); } catch (_error) {}
              },
              commit: function (collapsed) {
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
                this.el.removeEventListener("keydown", this.onKey);
                this.el.removeEventListener("pointerdown", this.onDown);
                this.el.removeEventListener("pointermove", this.onMove);
                this.el.removeEventListener("pointerup", this.onUp);
                this.el.removeEventListener("pointercancel", this.onCancel);
                this.el.removeEventListener("lostpointercapture", this.onCancel);
              }
            };
            Hooks.AxMenu = {
              mounted: function () {
                this.cog = this.el.querySelector("#ax-cog");
                this.menu = this.el.querySelector("#ax-menu");
                this.onClick = (e) => {
                  if (this.cog.contains(e.target)) this.setOpen(!this.el.classList.contains("open"));
                  else if (!this.el.contains(e.target)) this.setOpen(false);
                };
                this.onKey = (e) => {
                  if (!this.el.contains(e.target)) return;
                  var items = Array.from(this.menu.querySelectorAll("button:not(:disabled)"));
                  var index = items.indexOf(document.activeElement);
                  var onCog = this.cog.contains(e.target);
                  if (e.key === "Escape") { e.preventDefault(); this.setOpen(false); this.cog.focus(); return; }
                  if (e.key === "Tab") { this.setOpen(false); return; }
                  if (onCog && ["Enter", " ", "ArrowDown", "ArrowUp"].includes(e.key)) {
                    e.preventDefault(); this.setOpen(true);
                    items[e.key === "ArrowUp" ? items.length - 1 : 0]?.focus();
                  } else if (!onCog && ["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) {
                    e.preventDefault();
                    var next = e.key === "Home" ? 0 : e.key === "End" ? items.length - 1 :
                      (index + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
                    items[next]?.focus();
                  }
                };
                document.addEventListener("click", this.onClick);
                document.addEventListener("keydown", this.onKey);
              },
              setOpen: function (open) {
                this.el.classList.toggle("open", open);
                this.cog.setAttribute("aria-expanded", String(open));
                this.menu.inert = !open;
              },
              destroyed: function () {
                document.removeEventListener("click", this.onClick);
                document.removeEventListener("keydown", this.onKey);
              }
            };

            // Provider usage is polled from a rate-limited endpoint, so it is
            // polled only while someone is actually looking. Report focus to
            // the server; it keeps polling for a grace period after the last
            // watcher looks away, and stops entirely once a tab is abandoned.
            Hooks.UsageWatch = {
              mounted: function () {
                this.report = () => {
                  var watching = document.visibilityState === "visible" && document.hasFocus();
                  if (watching === this.lastReported) return;
                  this.lastReported = watching;
                  this.pushEvent(watching ? "usage-watch-start" : "usage-watch-stop", {});
                };

                this.onVisibility = this.report;
                this.onFocus = this.report;
                this.onBlur = this.report;

                document.addEventListener("visibilitychange", this.onVisibility);
                window.addEventListener("focus", this.onFocus);
                window.addEventListener("blur", this.onBlur);

                this.report();
              },
              destroyed: function () {
                document.removeEventListener("visibilitychange", this.onVisibility);
                window.removeEventListener("focus", this.onFocus);
                window.removeEventListener("blur", this.onBlur);
              }
            };

            Hooks.ThemeToggle = {
              mounted: function () {
                this.onClick = () => {
                  var current = document.documentElement.dataset.theme === "light" ? "light" : "dark";
                  var next = current === "light" ? "dark" : "light";
                  document.documentElement.dataset.theme = next;

                  try {
                    window.localStorage.setItem("aiur-theme", next);
                  } catch (_error) {}
                };

                this.el.addEventListener("click", this.onClick);
              },
              destroyed: function () {
                this.el.removeEventListener("click", this.onClick);
              }
            };

            Hooks.PaletteToggle = {
              mounted: function () {
                this.sync();
                this.onClick = () => {
                  var next = document.documentElement.dataset.palette === "gruvbox" ? "aiur" : "gruvbox";
                  document.documentElement.dataset.palette = next;
                  try { window.localStorage.setItem("aiur-palette", next); } catch (_error) {}
                  this.sync();
                };
                this.el.addEventListener("click", this.onClick);
              },
              updated: function () { this.sync(); },
              destroyed: function () { this.el.removeEventListener("click", this.onClick); },
              sync: function () {
                var state = this.el.getAttribute("role") === "menuitemcheckbox" ? "aria-checked" : "aria-pressed";
                this.el.setAttribute(state, String(document.documentElement.dataset.palette === "gruvbox"));
              }
            };

            Hooks.CopyToClipboard = {
              mounted: function () {
                this.source = this.el.querySelector("[data-copy-source]");
                this.trigger = this.el.querySelector("[data-copy-trigger]");
                this.status = this.el.querySelector("[data-copy-status]");

                this.onCopy = async () => {
                  if (!this.source || !this.trigger) return;

                  try {
                    var copied = false;

                    if (navigator.clipboard?.writeText) {
                      try {
                        await navigator.clipboard.writeText(this.sourceText());
                        copied = true;
                      } catch (_error) {}
                    }

                    if (!copied) {
                      this.selectSource();
                      copied = document.execCommand("copy");
                    }

                    if (!copied) throw new Error("copy unavailable");
                    if (this.status) this.status.textContent = "Copied";
                  } catch (_error) {
                    this.selectSource();
                    if (this.status) this.status.textContent = "Copy unavailable — prompt selected";
                  }
                };

                this.trigger?.addEventListener("click", this.onCopy);
              },
              destroyed: function () {
                this.trigger?.removeEventListener("click", this.onCopy);
              },
              // A copy source is either a form control (`value`) or a plain
              // block that renders the text itself. The block form exists so a
              // long prompt can lay out over as many wrapped rows as it needs:
              // a textarea has a fixed row count and would clip the tail.
              sourceText: function () {
                return "value" in this.source ? this.source.value : this.source.textContent;
              },
              selectSource: function () {
                if (typeof this.source.select === "function") {
                  this.source.focus();
                  this.source.select();
                  this.source.setSelectionRange(0, this.source.value.length);
                  return;
                }

                // `selectSource` runs from the failure handler too, so it must
                // not throw: a null selection here would escape that handler
                // and leave the button dead with no status message.
                var selection = window.getSelection();
                if (!selection) return;

                var range = document.createRange();
                range.selectNodeContents(this.source);
                selection.removeAllRanges();
                selection.addRange(range);
              }
            };

            if (window.AiurTicketContextDialogHook) {
              Hooks.TicketContextDialog = window.AiurTicketContextDialogHook;
            }

            if (window.AiurConversationDrawerHook) {
              Hooks.ConversationDrawer = window.AiurConversationDrawerHook;
            }

            if (window.AiurDomSvgLayout) {
              Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook();
            }

            if (window.AiurBuildOrderGridHook) {
              Hooks.BuildOrderGrid = window.AiurBuildOrderGridHook;
            }

            if (window.AiurTimeBrushHook) {
              Hooks.TimeBrush = window.AiurTimeBrushHook.createLiveViewHook();
            }

            if (window.AiurStreamdeckEmulatorHook) {
              Hooks.StreamdeckEmulator = window.AiurStreamdeckEmulatorHook;
            }

            if (window.AiurSortableTableHook) {
              Hooks.SortableTable = window.AiurSortableTableHook;
            }

            if (window.AiurBuildHome) {
              Hooks.BuildHome = window.AiurBuildHome.createLiveViewHook();
            }

            // LiveView also uses storage during boot; denied storage must not prevent hooks mounting.
            function availableStorage(name) {
              try {
                var storage = window[name];
                storage.getItem("aiur-storage-probe");
                return storage;
              } catch (_error) {
                var values = {};
                return {
                  getItem: key => values[key] ?? null,
                  setItem: (key, value) => { values[key] = String(value); },
                  removeItem: key => { delete values[key]; }
                };
              }
            }

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: Hooks,
              localStorage: availableStorage("localStorage"),
              sessionStorage: availableStorage("sessionStorage"),
              params: {
                _csrf_token: csrfToken,
                time_zone: (function () {
                  try {
                    return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
                  } catch (e) {
                    return null;
                  }
                })()
              }
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
        <link rel="stylesheet" href="/build-home/home.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end

  # Names the repo this daemon is running against, so several instances are
  # tellable apart in a tab strip — the reason the old fixed title was useless.
  # Uses the same identity the TUI's Project row shows rather than resolving the
  # repo a second way.
  defp page_title do
    case repo_label() do
      nil -> "Aiur Dashboard"
      label -> "Aiur: #{label} Dashboard"
    end
  end

  defp repo_label do
    case Aiur.Tracker.project_identity() do
      value when is_binary(value) and value != "" -> value |> repo_name() |> capitalize()
      _unavailable -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  # `project_identity/0` may carry an owner ("owner/repo"); the tab only has
  # room for the part that distinguishes one instance from another.
  defp repo_name(value), do: value |> String.split("/") |> List.last()

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(value), do: value
end
