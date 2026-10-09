defmodule AiurWeb.OperatorControlCenter.DashboardShell do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.RouteRegistry
  alias Phoenix.LiveView.JS

  attr(:route, :map, required: true)
  attr(:routes, :list, required: true)
  attr(:title, :string, default: nil)
  attr(:back_path, :string, default: nil)
  attr(:back_label, :string, default: "Back")
  attr(:tracker_kind, :string, required: true)
  attr(:agent_kind, :string, required: true)
  attr(:nav_counts, :map, default: %{})
  # Server-owned so a LiveView re-render cannot revert it. A client-only
  # attribute on this element is stripped by the next DOM patch, which is what
  # made the toggle spring back open (#1306).
  attr(:nav_collapsed, :boolean, default: false)
  # The single global pause switch. Server-owned (mirrors the orchestrator's
  # state), writable-gated like every other control surface.
  attr(:globally_paused, :any, default: nil)
  attr(:writable, :boolean, default: false)
  # Notices precede page content.
  slot(:banner)
  slot(:inner_block, required: true)

  @spec dashboard_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_shell(assigns) do
    ~H"""
    <div class="ax-frame" id="ax-frame">
      <header class="ax-top">
        <div class="ax-brand">
          <img class="brand-logo" src="/aiur-logo.png" alt="Aiur" />
          <span class="wm">aiur</span>
          <div class="ax-set" id="ax-set" phx-hook="AxMenu"
            phx-mounted={JS.ignore_attributes(["class"]) |> JS.ignore_attributes(["aria-expanded"], to: "#ax-cog") |> JS.ignore_attributes(["inert"], to: "#ax-menu")}>
            <button class="ax-ib ax-cog" id="ax-cog" type="button" title="Settings" aria-label="Settings"
              aria-haspopup="menu" aria-expanded="false" aria-controls="ax-menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg></button>
            <div class="ax-menu" id="ax-menu" role="menu" aria-labelledby="ax-cog" inert>
              <.pause_item globally_paused={@globally_paused} writable={@writable} />
              <.theme_item />
              <.palette_button />
            </div>
          </div>
        </div>
        <div class="ax-title" id="ax-title">
          <.link :if={@back_path} patch={@back_path} class="ax-back" aria-label={@back_label}>
            <span aria-hidden="true">{nav_icon(@route.id)}</span>
          </.link>
          <b id="route-title" role="heading" aria-level="1">{@title || @route.label}</b>
          <span class="status-badge status-badge-offline brand-live"><span class="status-badge-dot"></span>Offline</span>
        </div>
        <span class={["ax-paused", @globally_paused == true && "show"]} id="ax-paused">All agents paused</span>
      </header>
      <div class="app-layout">
        <aside class="sidenav">
          <div class="ax-drag" id="ax-drag" phx-hook="NavToggle" data-nav-collapsed={to_string(@nav_collapsed)}
            role="separator" aria-orientation="vertical" aria-label="Drag to resize navigation" title="Drag to resize"
            tabindex="0" aria-controls="ax-nav" aria-valuemin="60" aria-valuemax="188" aria-valuenow={if @nav_collapsed, do: 60, else: 188}></div>
          <.navigation routes={@routes} current_route={@route} nav_counts={@nav_counts} />
        </aside>
        <section class="dashboard-shell" aria-labelledby="route-title">
          {render_slot(@banner)}
          {render_slot(@inner_block)}
        </section>
      </div>
    </div>
    """
  end

  attr(:globally_paused, :any, required: true)
  attr(:writable, :boolean, required: true)

  defp pause_item(assigns) do
    ~H"""
    <button id="ax-pause" class={["ax-mi", @globally_paused == true && "on"]} type="button" role={if is_boolean(@globally_paused), do: "menuitemcheckbox", else: "menuitem"}
      phx-click="toggle-global-pause" disabled={not @writable or is_nil(@globally_paused)}
      aria-disabled={to_string(not @writable or is_nil(@globally_paused))}
      aria-checked={if is_boolean(@globally_paused), do: to_string(@globally_paused)}
      title={pause_title(@globally_paused, @writable)}>
      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="7" y="5" width="3.4" height="14" rx="1.1"/><rect x="13.6" y="5" width="3.4" height="14" rx="1.1"/></svg>
      <span>{pause_label(@globally_paused)}</span><i :if={is_boolean(@globally_paused)} class="ax-sw"></i>
    </button>
    """
  end

  defp theme_item(assigns) do
    ~H"""
    <button id="theme-toggle" class="ax-mi" type="button" role="menuitem" phx-hook="ThemeToggle">
      <span class="toggle-icon" aria-hidden="true">
        <svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
        <svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>
      </span><span>Switch theme</span>
    </button>
    """
  end

  defp palette_button(assigns) do
    ~H"""
    <button id="ax-palette" class="ax-mi" type="button" phx-hook="PaletteToggle"
      role="menuitemcheckbox" aria-checked="true">
      <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="13.5" cy="6.5" r="1.5"/><circle cx="17.5" cy="10.5" r="1.5"/><circle cx="8.5" cy="7.5" r="1.5"/><circle cx="6.5" cy="12.5" r="1.5"/><path d="M12 2a10 10 0 0 0 0 20c1.1 0 2-.9 2-2 0-.5-.2-1-.5-1.3-.3-.4-.5-.8-.5-1.3 0-1.1.9-2 2-2h2.4A5.6 5.6 0 0 0 22 9.8C22 5.5 17.5 2 12 2z"/></svg><span>Gruvbox palette</span><i class="ax-sw"></i>
    </button>
    """
  end

  attr(:routes, :list, required: true)
  attr(:current_route, :map, required: true)
  attr(:nav_counts, :map, default: %{})

  defp navigation(assigns) do
    ~H"""
    <nav class="sidenav-nav" id="ax-nav" aria-label="Views">
      <%= for route <- @routes do %>
        <.route_item
          route={route}
          current_route={@current_route}
          count={Map.get(@nav_counts, route.id)}
          active={route.id == @current_route.id}
        />
      <% end %>
    </nav>
    """
  end

  attr(:route, :map, required: true)
  attr(:current_route, :map, required: true)
  attr(:count, :any, default: nil)
  attr(:active, :boolean, required: true)

  defp route_item(assigns) do
    assigns =
      assigns
      |> assign(:available, RouteRegistry.available?(assigns.route))
      |> assign(:navigation_mode, RouteRegistry.navigation_mode(assigns.current_route, assigns.route))

    ~H"""
    <.link
      :if={@available and RouteRegistry.live?(@route) and @navigation_mode == :patch}
      patch={@route.path}
      class={["snav", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="snav-ic" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="snav-label">{Map.get(@route, :nav_label, @route.label)}</span>
      <.nav_count route_id={@route.id} count={@count} />
    </.link>
    <.link
      :if={@available and RouteRegistry.live?(@route) and @navigation_mode == :navigate}
      navigate={@route.path}
      class={["snav", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="snav-ic" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="snav-label">{Map.get(@route, :nav_label, @route.label)}</span>
      <.nav_count route_id={@route.id} count={@count} />
    </.link>
    <.link
      :if={@available and RouteRegistry.document?(@route)}
      href={@route.path}
      class="snav"
    >
      <span class="snav-ic" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="snav-label">{Map.get(@route, :nav_label, @route.label)}</span>
    </.link>
    <span
      :if={!@available}
      class="snav is-soon"
      aria-label={"#{@route.label} coming soon"}
      aria-disabled="true"
      title={@route.description}
    >
      <span class="snav-ic" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="snav-label">{Map.get(@route, :nav_label, @route.label)}</span>
      <span class="snav-soon">Coming soon</span>
    </span>
    """
  end

  attr(:route_id, :atom, required: true)
  attr(:count, :any, required: true)

  defp nav_count(%{route_id: :commands, count: count} = assigns) when is_integer(count) and count > 0 do
    ~H"""
    <span class="snav-c attn" title={"#{@count} need a command"} aria-hidden="true">{@count}</span>
    <span class="sr-only">, {@count} need a command</span>
    """
  end

  defp nav_count(%{route_id: :commands} = assigns), do: ~H""

  defp nav_count(%{count: count} = assigns) when is_integer(count) and count >= 0 do
    ~H"""
    <span class="snav-c" aria-hidden="true">{@count}</span>
    """
  end

  defp nav_count(assigns), do: ~H""

  @nav_svg_attrs ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round")

  defp nav_icon(id) when id in [:units, :build] do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>)
    )
  end

  defp nav_icon(:commands) do
    Phoenix.HTML.raw(~s(<svg #{@nav_svg_attrs}><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg>))
  end

  defp nav_icon(:build_order) do
    Phoenix.HTML.raw(~s(<svg #{@nav_svg_attrs}><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="8" r="3"/><path d="M6 9v6"/><path d="M18 11a9 9 0 0 1-9 9"/></svg>))
  end

  defp nav_icon(:analytics) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><path d="M3 3v18h18"/><rect x="7" y="12" width="3" height="5"/><rect x="12" y="8" width="3" height="9"/><rect x="17" y="5" width="3" height="12"/></svg>)
    )
  end

  defp nav_icon(:streamdeck) do
    Phoenix.HTML.raw(
      ~s(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2" y="4" width="20" height="16" rx="2.5"/><circle cx="7" cy="9" r="1.7"/><circle cx="12" cy="9" r="1.7"/><circle cx="17" cy="9" r="1.7"/><circle cx="7" cy="15" r="1.7"/><circle cx="12" cy="15" r="1.7"/><circle cx="17" cy="15" r="1.7"/></svg>)
    )
  end

  defp nav_icon(_id) do
    Phoenix.HTML.raw(~s(<svg #{@nav_svg_attrs}><circle cx="12" cy="12" r="9"/></svg>))
  end

  defp pause_label(nil), do: "Pause state unknown"
  defp pause_label(true), do: "Resume all agents"
  defp pause_label(false), do: "Pause all agents"

  defp pause_title(nil, _writable), do: "The daemon's pause state is not available"
  defp pause_title(_paused, false), do: "Read-only dashboard: pausing is unavailable"
  defp pause_title(paused, true), do: pause_label(paused)
end
