defmodule AiurWeb.OperatorControlCenter.DashboardShell do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.RouteRegistry

  attr(:route, :map, required: true)
  attr(:routes, :list, required: true)
  attr(:now, :any, required: true)
  attr(:tracker_kind, :string, required: true)
  attr(:agent_kind, :string, required: true)
  attr(:nav_counts, :map, default: %{})
  slot(:inner_block, required: true)

  @spec dashboard_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_shell(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <aside class="shell-sidebar" aria-label="Aiur navigation">
        <div class="brand-row">
          <img class="brand-mini-logo" src="/aiur-logo.png" alt="Aiur" />
          <span class="brand-wordmark"><b>aiur</b></span>
          <span class="status-badge status-badge-live brand-live">
            <span class="status-badge-dot"></span>Live
          </span>
          <span class="status-badge status-badge-offline brand-live">
            <span class="status-badge-dot"></span>Offline
          </span>
          <button
            id="theme-toggle"
            class="tool-btn icon-only"
            type="button"
            phx-hook="ThemeToggle"
            aria-label="Toggle color theme"
            title="Toggle color theme"
          >
            <span class="toggle-icon" aria-hidden="true">
              <svg class="sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
              </svg>
              <svg class="moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z" />
              </svg>
            </span>
          </button>
        </div>
        <.navigation
          routes={@routes}
          current_route={@route}
          nav_counts={@nav_counts}
          class="shell-nav shell-nav-sidebar"
          label="Aiur sidebar routes"
        />
      </aside>

      <div class="shell-main">
        <header class="topbar">
          <div class="route-context">
            <h1 id="route-title">{@route.label}</h1>
            <p :if={@route.description not in [nil, ""]}>{@route.description}</p>
          </div>
          <div class="toolbar">
            <time class="status-badge mono num" datetime={datetime_value(@now)}>{clock_value(@now)}</time>
          </div>
        </header>

        <div class="shell-content" aria-labelledby="route-title">
          {render_slot(@inner_block)}
        </div>
      </div>

      <.navigation
        routes={@routes}
        current_route={@route}
        nav_counts={@nav_counts}
        class="shell-nav shell-nav-mobile"
        label="Aiur mobile routes"
      />
    </section>
    """
  end

  attr(:routes, :list, required: true)
  attr(:current_route, :map, required: true)
  attr(:nav_counts, :map, default: %{})
  attr(:class, :string, required: true)
  attr(:label, :string, required: true)

  defp navigation(assigns) do
    ~H"""
    <nav class={@class} aria-label={@label}>
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
      class={["shell-nav-item", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="shell-nav-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="shell-nav-label">{@route.label}</span>
      <.nav_count route_id={@route.id} count={@count} />
    </.link>
    <.link
      :if={@available and RouteRegistry.live?(@route) and @navigation_mode == :navigate}
      navigate={@route.path}
      class={["shell-nav-item", @active && "is-active"]}
      aria-current={if @active, do: "page"}
    >
      <span class="shell-nav-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="shell-nav-label">{@route.label}</span>
      <.nav_count route_id={@route.id} count={@count} />
    </.link>
    <.link
      :if={@available and RouteRegistry.document?(@route)}
      href={@route.path}
      class="shell-nav-item"
    >
      <span class="shell-nav-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="shell-nav-label">{@route.label}</span>
    </.link>
    <span
      :if={!@available}
      class="shell-nav-item is-unavailable"
      aria-label={"#{@route.label} unavailable"}
      aria-disabled="true"
      title={@route.description}
    >
      <span class="shell-nav-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="shell-nav-label">{@route.label}</span>
      <span class="shell-nav-state">Unavailable</span>
    </span>
    """
  end

  attr(:route_id, :atom, required: true)
  attr(:count, :any, required: true)

  defp nav_count(%{count: count} = assigns) when is_integer(count) and count > 0 do
    ~H"""
    <span class={["shell-nav-count", @route_id == :commands && "is-attention"]} aria-hidden="true">
      {@count}
    </span>
    """
  end

  defp nav_count(assigns), do: ~H""

  @nav_svg_attrs ~s(viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round")

  defp nav_icon(:units) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>)
    )
  end

  defp nav_icon(:commands) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg>)
    )
  end

  defp nav_icon(:build_order) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="8" r="3"/><path d="M6 9v6"/><path d="M18 11a9 9 0 0 1-9 9"/></svg>)
    )
  end

  defp nav_icon(:analytics) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><path d="M3 3v18h18"/><rect x="7" y="12" width="3" height="5"/><rect x="12" y="8" width="3" height="9"/><rect x="17" y="5" width="3" height="12"/></svg>)
    )
  end

  defp nav_icon(_id) do
    Phoenix.HTML.raw(~s(<svg #{@nav_svg_attrs}><circle cx="12" cy="12" r="9"/></svg>))
  end

  defp clock_value(%DateTime{} = now), do: Calendar.strftime(now, "%H:%M:%S")
  defp clock_value(_now), do: "--:--:--"
  defp datetime_value(%DateTime{} = now), do: DateTime.to_iso8601(now)
  defp datetime_value(_now), do: nil
end
