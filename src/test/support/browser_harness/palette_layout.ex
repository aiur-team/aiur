defmodule Aiur.BrowserHarness.FixtureLayout do
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark" data-palette="gruvbox">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Aiur browser harness fixture</title>
        <style>
          :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
          body { margin: 0; }
          main { display: grid; min-width: 0; gap: 1rem; padding: 1rem; }
          main > *, nav, .controls { min-width: 0; }
          nav, .controls { display: flex; flex-wrap: wrap; gap: .5rem; }
          nav button, .controls button { min-width: 0; max-width: 100%; overflow-wrap: anywhere; }
          button:focus-visible, [tabindex="0"]:focus-visible { outline: 3px solid currentColor; outline-offset: 3px; }
          #graph-viewport { border: 1px solid currentColor; min-width: 0; min-height: 8rem; overflow: auto; padding: 1rem; }
          #graph-content { min-width: 36rem; }
          @media (prefers-reduced-motion: no-preference) { #graph-content { transition: transform 120ms ease; } }
        </style>
        <script defer src="/assets/phoenix_html.js"></script>
        <script defer src="/assets/phoenix.js"></script>
        <script defer src="/assets/phoenix_live_view.js"></script>
        <script defer src="/aiur-dom-svg-layout-loader.js"></script>
        <script defer src="/conversation-voice-controller.js"></script>
        <script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/assets/time-brush-hook.js"></script>
        <script defer src="/assets/ticket-context-dialog-hook.js"></script>
        <script defer src="/assets/build-order-grid-hook.js"></script>
        <script defer src="/assets/streamdeck-emulator-hook.js"></script>
        <script defer src="/assets/sortable-table-hook.js"></script>
        <script defer src="/build-home/loader.js"></script>
        <script defer src="/assets/browser_harness.js"></script>
        <link rel="stylesheet" href="/dashboard.css" />
        <link rel="stylesheet" href="/build-home/home.css" />
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            window.BrowserHarnessHooks.NavToggle = {
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

            window.BrowserHarnessHooks.ThemeToggle = {
              mounted: function () {
                this.onClick = () => {
                  var current = document.documentElement.dataset.theme === "light" ? "light" : "dark";
                  var next = current === "light" ? "dark" : "light";
                  document.documentElement.dataset.theme = next;
                  this.el.setAttribute("aria-label", "Switch to " + current + " theme");
                };

                this.el.addEventListener("click", this.onClick);
              },
              destroyed: function () {
                this.el.removeEventListener("click", this.onClick);
              }
            };

            // Production-layout probe tests constrain this fixture copy.
            window.BrowserHarnessHooks.PaletteToggle = {
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

            if (window.AiurTicketContextDialogHook) {
              window.BrowserHarnessHooks.TicketContextDialog = window.AiurTicketContextDialogHook;
            }

            if (window.AiurConversationDrawerHook) {
              window.BrowserHarnessHooks.ConversationDrawer = window.AiurConversationDrawerHook;
            }

            if (window.AiurBuildOrderGridHook) {
              window.BrowserHarnessHooks.BuildOrderGrid = window.AiurBuildOrderGridHook;
            }

            if (window.AiurStreamdeckEmulatorHook) {
              window.BrowserHarnessHooks.StreamdeckEmulator = window.AiurStreamdeckEmulatorHook;
            }

            if (window.AiurSortableTableHook) {
              window.BrowserHarnessHooks.SortableTable = window.AiurSortableTableHook;
            }

            if (window.AiurBuildHome) {
              window.BrowserHarnessHooks.BuildHome = window.AiurBuildHome.createLiveViewHook();
            }

            window.liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: window.BrowserHarnessHooks,
              params: {_csrf_token: csrfToken}
            });
            window.liveSocket.connect();
          });
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end

defmodule Aiur.BrowserHarness.PaletteProbeLive do
  use Phoenix.LiveView, layout: false
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  def mount(_params, _session, socket) do
    {:ok, NavState.assign_nav(socket)}
  end

  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <DashboardShell.dashboard_shell route={RouteRegistry.current_route(:index)} routes={RouteRegistry.routes(%{})}
        tracker_kind="fixture" agent_kind="fixture" nav_collapsed={@nav_collapsed}>
        <button id="probe-palette-button" type="button" aria-pressed="true" phx-hook="PaletteToggle" data-probe-patch={to_string(@nav_collapsed)}>Gruvbox palette button</button>
        <button id="probe-palette-item" type="button" role="menuitemcheckbox" aria-checked="true" phx-hook="PaletteToggle" data-probe-patch={to_string(@nav_collapsed)}>Gruvbox palette</button>
      </DashboardShell.dashboard_shell>
    </main>
    """
  end
end
