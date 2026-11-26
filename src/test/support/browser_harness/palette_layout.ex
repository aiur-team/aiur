defmodule Aiur.BrowserHarness.FixtureLayout do
  @moduledoc false
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
          nav:not(.sidenav-nav), .controls { display: flex; flex-wrap: wrap; gap: .5rem; }
          nav button, .controls button { min-width: 0; max-width: 100%; overflow-wrap: anywhere; }
          #fixture-viewport { border: 1px solid currentColor; min-width: 0; min-height: 8rem; overflow: auto; padding: 1rem; }
          #fixture-content { min-width: 36rem; }
          @media (prefers-reduced-motion: no-preference) { #fixture-content { transition: transform 120ms ease; } }
        </style>
        <script defer src="/assets/phoenix_html.js"></script>
        <script defer src="/assets/phoenix.js"></script>
        <script defer src="/assets/phoenix_live_view.js"></script>
        <script defer src="/nav-toggle-hook.js"></script>
        <script defer src="/aiur-dom-svg-layout-loader.js"></script>
        <script defer src="/voice-capture.js"></script>
        <script defer src="/voice-transport.js"></script><script defer src="/voice-mode-choice.js"></script>
        <script defer src="/voice-waveform.js"></script><script defer src="/voice-playback.js"></script><script defer src="/conversation-voice-controller.js"></script>
        <script defer src="/executor-voice-controller.js"></script><script defer src="/executor-voice-hook.js"></script><script defer src="/voice-input-hook.js"></script><script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/assets/time-brush-hook.js"></script>
        <script defer src="/assets/ticket-context-dialog-hook.js"></script>
        <script defer src="/assets/streamdeck-emulator-knob.js"></script>
        <script defer src="/assets/streamdeck-emulator-hook.js"></script>
        <script defer src="/assets/sortable-table-hook.js"></script>
        <script defer src="/decision-questions-validation.js"></script>
        <script defer src="/build-home/loader.js"></script>
        <script defer src="/assets/browser_harness.js"></script>
        <link rel="stylesheet" href="/aiur-style/tokens.css" />
        <link rel="stylesheet" href="/aiur-style/css/focus.css" />
        <link rel="stylesheet" href="/aiur-style/css/button.css" />
        <link rel="stylesheet" href="/aiur-style/css/dashboard-button.css" />
        <link rel="stylesheet" href="/aiur-style/css/dashboard-shell.css" />
        <link rel="stylesheet" href="/dashboard.css" />
        <link rel="stylesheet" href="/build-home/home.css" />
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
            window.BrowserHarnessHooks.NavToggle = window.AiurNavToggleHook;
            window.BrowserHarnessHooks.AxMenu = {
              mounted: function () {
                this.cog = this.el.querySelector("#ax-cog");
                this.menu = this.el.querySelector("#ax-menu");
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
                window.removeEventListener("resize", this.onResize);
                this.brandObserver.disconnect();
              }
            };

            window.BrowserHarnessHooks.ThemeToggle = {
              mounted: function () {
                this.onClick = () => {
                  var current = document.documentElement.dataset.theme === "light" ? "light" : "dark";
                  var next = current === "light" ? "dark" : "light";
                  document.documentElement.dataset.theme = next;
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

            if (window.AiurVoiceInputHook) window.BrowserHarnessHooks.VoiceInput = window.AiurVoiceInputHook;
            if (window.AiurExecutorVoiceHook) window.BrowserHarnessHooks.ExecutorVoice = window.AiurExecutorVoiceHook;

            if (window.AiurConversationDrawerHook) {
              window.BrowserHarnessHooks.ConversationDrawer = window.AiurConversationDrawerHook;
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
              dom: { onBeforeElUpdated: window.AiurVoiceInputBeforeUpdate },
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
  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, Overview, RouteRegistry}

  def mount(params, _session, socket) do
    paused =
      case params["paused"] do
        "true" -> true
        "false" -> false
        _ -> nil
      end

    awaiting =
      case Integer.parse(params["awaiting"] || "unknown") do
        {count, ""} when count >= 0 -> count
        _ -> nil
      end

    counts = if is_integer(awaiting), do: %{needs_you: awaiting, needs_you_blocking: 0}, else: %{}

    {:ok,
     socket
     |> NavState.assign_nav()
     |> assign(paused: paused, writable: params["writable"] == "true", counts: counts, patch: 0)}
  end

  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  def handle_event("toggle-global-pause", _params, socket) do
    if socket.assigns.writable and is_boolean(socket.assigns.paused) do
      {:noreply, assign(socket, :paused, not socket.assigns.paused)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("patch-shell", _params, socket),
    do: {:noreply, update(socket, :patch, &(&1 + 1))}

  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <DashboardShell.dashboard_shell route={RouteRegistry.current_route(:index)} routes={RouteRegistry.routes(%{})}
        tracker_kind="fixture" agent_kind="fixture" nav_collapsed={@nav_collapsed}
        globally_paused={@paused} writable={@writable} nav_counts={%{commands: @counts[:needs_you]}}>
        <:banner><Overview.decisions_banner retained_counts={@counts} /></:banner>
        <button id="probe-patch" phx-click="patch-shell" data-patch={@patch}>Patch shell</button>
        <button id="probe-palette-button" type="button" aria-pressed="true" phx-hook="PaletteToggle" data-probe-patch={to_string(@nav_collapsed)}>Gruvbox palette button</button>
        <button id="probe-palette-item" type="button" role="menuitemcheckbox" aria-checked="true" phx-hook="PaletteToggle" data-probe-patch={to_string(@nav_collapsed)}>Gruvbox palette</button>
      </DashboardShell.dashboard_shell>
    </main>
    """
  end
end
