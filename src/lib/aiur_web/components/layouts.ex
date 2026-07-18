defmodule AiurWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Aiur Operator Control Center</title>
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

            if (window.AiurTicketContextDialogHook) {
              Hooks.TicketContextDialog = window.AiurTicketContextDialogHook;
            }

            if (window.AiurConversationDrawerHook) {
              Hooks.ConversationDrawer = window.AiurConversationDrawerHook;
            }

            if (window.AiurDomSvgLayout) {
              Hooks.DomSvgLayout = window.AiurDomSvgLayout.createLiveViewHook();
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
end
