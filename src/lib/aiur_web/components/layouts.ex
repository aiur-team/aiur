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
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <link rel="icon" type="image/png" href="/aiur-logo.png" />
        <link rel="apple-touch-icon" href="/aiur-logo.png" />
        <title>{@page_title}</title>
        <script>
          (function () {
            try {
              var stored = window.localStorage.getItem("aiur-theme");
              if (stored === "light" || stored === "dark") {
                document.documentElement.dataset.theme = stored;
              }
            } catch (_error) {}
          })();
        </script>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script defer src="/aiur-dom-svg-layout-loader.js"></script>
        <script defer src="/ticket-context-dialog-hook.js"></script>
        <script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/build-order-grid-hook.js"></script>
        <script defer src="/time-brush-hook.js"></script>
        <script defer src="/streamdeck-emulator-hook.js"></script>
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

            // The server owns the collapsed state (assigns -> data-nav-collapsed on
            // the shell). This hook only mirrors it to localStorage and replays the
            // stored value once on mount, so cross-navigation persistence survives
            // without any client-written attribute for LiveView to strip.
            Hooks.NavToggle = {
              mounted: function () {
                try {
                  var stored = window.localStorage.getItem("aiur-nav-collapsed");
                  if (stored === "true" || stored === "false") {
                    var collapsed = stored === "true";
                    if (collapsed !== (this.el.getAttribute("aria-pressed") === "true")) {
                      this.pushEvent("restore-nav", { collapsed: collapsed });
                    }
                  }
                } catch (_error) {}
              },
              updated: function () {
                try {
                  window.localStorage.setItem(
                    "aiur-nav-collapsed",
                    this.el.getAttribute("aria-pressed") === "true" ? "true" : "false"
                  );
                } catch (_error) {}
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
                  this.el.setAttribute("aria-label", "Switch to " + current + " theme");

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

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: Hooks,
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
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
