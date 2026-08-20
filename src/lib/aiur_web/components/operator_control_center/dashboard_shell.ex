defmodule AiurWeb.OperatorControlCenter.DashboardShell do
  @moduledoc false

  use Phoenix.Component

  alias AiurWeb.OperatorControlCenter.RouteRegistry

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
  attr(:globally_paused, :boolean, default: false)
  attr(:writable, :boolean, default: false)
  # Rendered above the route heading, for anything that should be read before
  # the page it interrupts.
  slot(:banner)
  slot(:inner_block, required: true)

  @spec dashboard_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def dashboard_shell(assigns) do
    ~H"""
    <section class="dashboard-shell" data-nav-collapsed={to_string(@nav_collapsed)}>
      <header class="topbar">
        <div class="brand-row">
          <img class="brand-mini-logo" src="/aiur-logo.png" alt="Aiur" />
          <span class="brand-wordmark"><b>aiur</b></span>
          <span class="status-badge status-badge-offline brand-live">
            <span class="status-badge-dot"></span>Offline
          </span>
        </div>
        <div class="toolbar">
          <%!-- The run-wide controls, at every resolution: top right, together.
                The pause switch sits beside the theme toggle rather than in the
                brand cluster, so the nav bar carries the brand and nothing
                else. --%>
          <div class="topbar-controls">
            <.global_pause_button
              id="global-pause-toggle"
              globally_paused={@globally_paused}
              writable={@writable}
            />
            <.theme_button id="theme-toggle" />
          </div>
        </div>
      </header>

      <div class="shell-body">
        <aside class="shell-sidebar" aria-label="Aiur navigation">
          <.navigation
            routes={@routes}
            current_route={@route}
            nav_counts={@nav_counts}
            class="shell-nav shell-nav-sidebar"
            label="Aiur sidebar routes"
          />
          <%!-- Hovers over the right edge of the first route, carrying its own
                drop shadow so it reads as a control laid on top of the sidebar
                rather than another route. It lives in the sidebar (not the
                topbar) so it stays next to what it collapses, and the sidebar
                keeps a bare-rail presence when collapsed so the button is still
                there to reopen it. Below 960px the whole sidebar is hidden and
                this goes with it: there is no sidebar to collapse there, and
                the mobile nav pill carries the routes instead. --%>
          <button
            id="nav-toggle"
            class="tool-btn icon-only shell-nav-toggle"
            type="button"
            phx-hook="NavToggle"
            phx-click="toggle-nav"
            aria-label={nav_toggle_label(@nav_collapsed)}
            aria-pressed={to_string(@nav_collapsed)}
            title={nav_toggle_label(@nav_collapsed)}
          >
            <span class="nav-toggle-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <rect x="3" y="4" width="18" height="16" rx="2" />
                <path d="M9 4v16" />
                <path :if={!@nav_collapsed} d="M3 4h6v16H3z" fill="currentColor" stroke="none" />
              </svg>
            </span>
          </button>
        </aside>

        <div class="shell-main">
          <%!-- A real region, not a plain div: the route heading it is named by
                now lives inside it, and `aria-labelledby` is ignored on a
                generic element. --%>
          <section class="shell-content" aria-labelledby="route-title">
            <%!-- The route heading leads its own content column rather than the
                  nav bar: the title belongs to the page, and the nav keeps only
                  the brand. --%>
            <div class="route-context">
              <%!-- The same glyph the nav uses for this route, so the heading and
                    the nav item read as the same thing. Decorative: the heading
                    text already names the route. --%>
              <h1 id="route-title" aria-label={@title || @route.label}>
                <.link :if={@back_path} patch={@back_path} class="route-title-icon route-title-back" aria-label={@back_label}>
                  <span aria-hidden="true">{nav_icon(@route.id)}</span>
                </.link>
                <span :if={is_nil(@back_path)} class="route-title-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
                <span>{@title || @route.label}</span>
              </h1>
              <p :if={@route.description not in [nil, ""]}>{@route.description}</p>
            </div>
            <%!-- Below the route heading: an alert that needs acting on should
                  still be read before the page it interrupts, but it now sits in
                  the standard content column at the standard pane width. --%>
            {render_slot(@banner)}
            {render_slot(@inner_block)}
          </section>
        </div>
      </div>

      <.navigation
        routes={@routes}
        current_route={@route}
        nav_counts={@nav_counts}
        class="shell-nav shell-nav-mobile"
        label="Aiur mobile routes"
      >
        <:trailing>
          <div class="shell-nav-controls">
            <.global_pause_button
              id="global-pause-toggle-mobile"
              globally_paused={@globally_paused}
              writable={@writable}
            />
          </div>
        </:trailing>
      </.navigation>
    </section>
    """
  end

  # The sidebar that normally hosts these controls is `display: none` below
  # 960px, so both are rendered a second time inside the mobile nav pill.
  # Duplicated markup needs distinct DOM ids — LiveView patches by id, and the
  # `ThemeToggle` hook is `this.el`-scoped so two instances coexist safely.
  attr(:id, :string, required: true)
  attr(:globally_paused, :boolean, required: true)
  attr(:writable, :boolean, required: true)

  defp global_pause_button(assigns) do
    ~H"""
    <button
      id={@id}
      class={"tool-btn icon-only global-pause-toggle" <> if(@globally_paused, do: " is-paused", else: "")}
      type="button"
      phx-click="toggle-global-pause"
      disabled={not @writable}
      aria-disabled={to_string(not @writable)}
      aria-pressed={to_string(@globally_paused)}
      aria-label={global_pause_label(@globally_paused)}
      title={global_pause_label(@globally_paused)}
    >
      <span class="global-pause-icon" aria-hidden="true">
        <svg :if={@globally_paused} viewBox="0 0 24 24" fill="currentColor" stroke="none">
          <path d="M8 5v14l11-7z" />
        </svg>
        <svg :if={!@globally_paused} viewBox="0 0 24 24" fill="currentColor" stroke="none">
          <rect x="6" y="5" width="4" height="14" rx="1" /><rect x="14" y="5" width="4" height="14" rx="1" />
        </svg>
      </span>
    </button>
    """
  end

  attr(:id, :string, required: true)

  defp theme_button(assigns) do
    ~H"""
    <button
      id={@id}
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
    """
  end

  attr(:routes, :list, required: true)
  attr(:current_route, :map, required: true)
  attr(:nav_counts, :map, default: %{})
  attr(:class, :string, required: true)
  attr(:label, :string, required: true)
  slot(:trailing)

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
      {render_slot(@trailing)}
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
      aria-label={"#{@route.label} coming soon"}
      aria-disabled="true"
      title={@route.description}
    >
      <span class="shell-nav-icon" aria-hidden="true">{nav_icon(@route.id)}</span>
      <span class="shell-nav-label">{@route.label}</span>
      <span class="shell-nav-state">Coming soon</span>
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

  # The device's bezel around its four keys: the border is what tells this glyph
  # apart from the Units four-square at nav size, so the keys shrink to leave
  # room for it rather than crowding the frame. 4-unit keys, not 5: the icon
  # renders at 18px with a 2-unit stroke, so a tighter gap between the keys puts
  # their strokes within a pixel of each other and the four blur into one block.
  defp nav_icon(:streamdeck) do
    Phoenix.HTML.raw(
      ~s(<svg #{@nav_svg_attrs}><rect x="2" y="2" width="20" height="20" rx="3"/><rect x="6" y="6" width="4" height="4" rx="1"/><rect x="14" y="6" width="4" height="4" rx="1"/><rect x="6" y="14" width="4" height="4" rx="1"/><rect x="14" y="14" width="4" height="4" rx="1"/></svg>)
    )
  end

  defp nav_icon(_id) do
    Phoenix.HTML.raw(~s(<svg #{@nav_svg_attrs}><circle cx="12" cy="12" r="9"/></svg>))
  end

  defp nav_toggle_label(true), do: "Show navigation"
  defp nav_toggle_label(_collapsed), do: "Hide navigation"

  defp global_pause_label(true), do: "Resume all agents (globally paused)"
  defp global_pause_label(_paused), do: "Pause all agents"
end
