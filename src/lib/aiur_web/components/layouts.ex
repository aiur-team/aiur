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
        <link rel="icon" type="image/png" href="/aiur-style/assets/aiur-logo.png" />
        <link rel="apple-touch-icon" href="/aiur-style/assets/aiur-logo.png" />
        <title>{@page_title}</title>
        <script>
          (function () {
            try { if (window.localStorage.getItem("aiur-nav-collapsed") === "true" && window.matchMedia("(min-width: 961px)").matches) document.documentElement.classList.add("nav-collapsed"); } catch (_error) {}
            try {
              if (window.localStorage.getItem("aiur-palette") === "aiur") {
                document.documentElement.dataset.palette = "aiur";
              }
            } catch (_error) {}
          })();
        </script>
        <script src="/aiur-style/init/theme-init.js" data-default="dark"></script>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script defer src="/nav-toggle-hook.js"></script>
        <script defer src="/aiur-dom-svg-layout-loader.js"></script>
        <script defer src="/ticket-context-dialog-hook.js"></script>
        <script defer src="/voice-capture.js"></script><script defer src="/voice-transport.js"></script><script defer src="/voice-mode-choice.js"></script><script defer src="/voice-waveform.js"></script><script defer src="/voice-playback.js"></script><script defer src="/conversation-voice-controller.js"></script>
        <script defer src="/executor-voice-controller.js"></script><script defer src="/executor-voice-hook.js"></script><script defer src="/voice-input-hook.js"></script><script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/conversation-scroll-hook.js"></script>
        <script defer src="/time-brush-hook.js"></script>
        <script defer src="/streamdeck-emulator-knob.js"></script>
        <script defer src="/streamdeck-emulator-hook.js"></script>
        <script defer src="/sortable-table-hook.js"></script>
        <script defer src="/decision-questions-validation.js"></script>
        <script defer src="/build-home/loader.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            // The loading shell is server-rendered before LiveView joins. Keep
            // Settings interactive during that gap instead of waiting for its hook.
            var axMenuOpen = false;
            var setAxMenuOpen = (open) => {
              axMenuOpen = open;
              var settings = document.getElementById("ax-set");
              var cog = settings?.querySelector("#ax-cog");
              var menu = settings?.querySelector("#ax-menu");
              if (!settings || !cog || !menu) return;
              settings.classList.toggle("open", open);
              cog.setAttribute("aria-expanded", String(open));
              menu.inert = !open;
            };
            document.addEventListener("click", (e) => {
              var settings = document.getElementById("ax-set");
              var cog = settings?.querySelector("#ax-cog");
              if (!settings || !cog) return;
              if (cog.contains(e.target)) setAxMenuOpen(!axMenuOpen);
              else if (!settings.contains(e.target)) setAxMenuOpen(false);
            });
            document.addEventListener("keydown", (e) => {
              var settings = document.getElementById("ax-set");
              var cog = settings?.querySelector("#ax-cog");
              var menu = settings?.querySelector("#ax-menu");
              if (!settings || !cog || !menu || !settings.contains(e.target)) return;
              var items = Array.from(menu.querySelectorAll("button:not(:disabled)"));
              var index = items.indexOf(document.activeElement);
              var onCog = cog.contains(e.target);
              if (e.key === "Escape") { e.preventDefault(); setAxMenuOpen(false); cog.focus(); return; }
              if (e.key === "Tab") { setAxMenuOpen(false); return; }
              if (onCog && ["Enter", " ", "ArrowDown", "ArrowUp"].includes(e.key)) {
                e.preventDefault(); setAxMenuOpen(true);
                items[e.key === "ArrowUp" ? items.length - 1 : 0]?.focus();
              } else if (!onCog && ["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) {
                e.preventDefault();
                var next = e.key === "Home" ? 0 : e.key === "End" ? items.length - 1 :
                  (index + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
                items[next]?.focus();
              }
            });

            if (!window.Phoenix || !window.LiveView) return;

            var Hooks = {ConversationScroll: window.AiurConversationScrollHook};

            Hooks.NavToggle = window.AiurNavToggleHook;
            Hooks.AxMenu = {
              mounted: function () {
                this.cog = this.el.querySelector("#ax-cog");
                this.menu = this.el.querySelector("#ax-menu");
                this.open = axMenuOpen || this.el.classList.contains("open");
                this.fitMenu = () => {
                  if (window.innerWidth <= 480) {
                    var available = Math.max(0, window.innerWidth - 32), minimum = Math.min(210, available);
                    this.menu.style.minWidth = minimum + "px";
                    this.menu.style.maxWidth = available + "px";
                    var rect = this.menu.getBoundingClientRect();
                    if (getComputedStyle(this.menu).position === "absolute") {
                      var left = Math.max(16, Math.min(rect.left, window.innerWidth - 16 - rect.width));
                      this.menu.style.left = left - this.el.getBoundingClientRect().left + "px";
                    }
                  } else ["min-width", "max-width", "left"].forEach(key => this.menu.style.removeProperty(key));
                };
                this.fitMenu(); this.onResize = () => this.fitMenu();
                window.addEventListener("resize", this.onResize);
                this.brandObserver = new ResizeObserver(this.fitMenu);
                this.brandObserver.observe(this.el.closest(".ax-brand"));
                this.setOpen(this.open);
              },
              updated: function () { this.setOpen(axMenuOpen); },
              setOpen: function (open) {
                this.open = open;
                setAxMenuOpen(open);
                this.el.classList.toggle("open", open);
                this.cog.setAttribute("aria-expanded", String(open));
                this.menu.inert = !open;
              },
              destroyed: function () {
                window.removeEventListener("resize", this.onResize);
                this.brandObserver.disconnect();
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
                  if (this.theme) this.theme.setTheme(this.theme.getTheme() === "dark" ? "light" : "dark");
                };

                this.el.addEventListener("click", this.onClick);
                import("/aiur-style/js/theme.js").then((theme) => { this.theme = theme; });
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

            if (window.AiurVoiceInputHook) Hooks.VoiceInput = window.AiurVoiceInputHook;
            if (window.AiurExecutorVoiceHook) Hooks.ExecutorVoice = window.AiurExecutorVoiceHook;
            if (window.AiurConversationDrawerHook) Hooks.ConversationDrawer = window.AiurConversationDrawerHook;
            if (window.AiurDomSvgLayout) {
              Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook();
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
              dom: { onBeforeElUpdated: window.AiurVoiceInputBeforeUpdate },
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
            var socketStatus = document.documentElement;
            var socket = liveSocket.getSocket();
            socket.onOpen(() => socketStatus.classList.add("live-socket-connected"));
            var markSocketDown = () => socketStatus.classList.remove("live-socket-connected");
            socket.onClose(markSocketDown);
            socket.onError(markSocketDown);
            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/aiur-style/tokens.css" /><link rel="stylesheet" href="/aiur-style/css/focus.css" />
        <link rel="stylesheet" href="/aiur-style/css/button.css" />
        <link rel="stylesheet" href="/aiur-style/css/dashboard-button.css" />
        <link rel="stylesheet" href="/aiur-style/css/dashboard-shell.css" />
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
