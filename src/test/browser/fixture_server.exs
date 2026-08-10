Code.require_file("../support/browser_harness/fixtures.ex", __DIR__)

defmodule Aiur.BrowserHarness.FixtureLayout do
  use Phoenix.Component

  def app(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
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
        <script defer src="/conversation-drawer-hook.js"></script>
        <script defer src="/assets/time-brush-hook.js"></script>
        <script defer src="/assets/ticket-context-dialog-hook.js"></script>
        <script defer src="/assets/build-order-grid-hook.js"></script>
        <script defer src="/assets/streamdeck-emulator-hook.js"></script>
        <script defer src="/assets/browser_harness.js"></script>
        <link rel="stylesheet" href="/dashboard.css" />
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

defmodule Aiur.BrowserHarness.RouteShellLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias AiurWeb.OperatorControlCenter.{DashboardShell, NavState, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:analytics, analytics(%{}))
     |> NavState.assign_nav()
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:analytics, analytics(params))
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
  end

  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket), do: {:noreply, NavState.restore(socket, collapsed)}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <DashboardShell.dashboard_shell
        route={@current_route}
        routes={RouteRegistry.routes(@analytics)}
        tracker_kind="fixture"
        agent_kind="fixture"
        nav_collapsed={@nav_collapsed}
      >
        <section class="section-card" aria-labelledby="route-shell-fixture-title">
          <h2 id="route-shell-fixture-title">Route shell fixture</h2>
          <p>This authenticated LiveView fixture verifies the shared route shell without inventing operational data.</p>
          <button id="route-shell-action" type="button">Reachable action</button>
        </section>
      </DashboardShell.dashboard_shell>
    </main>
    """
  end

  defp analytics(%{"analytics" => "unavailable"}) do
    %{available?: false, path: nil, message: "Telemetry analytics are unavailable in this fixture."}
  end

  defp analytics(_params) do
    %{available?: true, path: "/analytics", message: "Open fixture analytics."}
  end
end

defmodule Aiur.BrowserHarness.FixtureLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BrowserHarness.Fixtures
  alias Aiur.BuildOrder.Icon
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderGraph

  @impl true
  def mount(_params, %{"fixture_access" => access}, socket) do
    fixture = Fixtures.graph(20)

    {:ok,
     socket
     |> assign(:fixture, fixture)
     |> assign(:mode, access)
     |> assign(:theme, :light)
     |> assign(:interaction, "Awaiting input")
     |> assign(:view, :overview)
     |> assign(:reduced_motion, false)
     |> assign(:worker_ready, false)
     |> assign(:graph_generation, 1)
     |> assign(:graph_mounted, true)
     |> assign(:graph_layout_mode, :worker)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "details", do: :details, else: :overview
    {:noreply, socket |> assign(:view, view) |> apply_fixture_size(params["size"])}
  end

  defp apply_fixture_size(socket, size) do
    case parse_fixture_size(size) do
      nil ->
        socket

      requested when requested == length(socket.assigns.fixture.nodes) ->
        socket

      requested ->
        socket
        |> assign(:fixture, Fixtures.graph(requested))
        |> update(:graph_generation, &(&1 + 1))
    end
  end

  defp parse_fixture_size(nil), do: nil

  defp parse_fixture_size(size) do
    case Integer.parse(size) do
      {value, ""} when value in [20, 50, 100] -> value
      _ -> nil
    end
  end

  @impl true
  def handle_event("navigate", %{"view" => view}, socket) when view in ["overview", "details"] do
    {:noreply, push_patch(socket, to: "/fixture?view=#{view}")}
  end

  def handle_event("set-theme", %{"theme" => "dark"}, socket), do: {:noreply, assign(socket, :theme, :dark)}
  def handle_event("set-theme", _params, socket), do: {:noreply, assign(socket, :theme, :light)}

  def handle_event("input", %{"kind" => kind}, socket) when kind in ["pointer", "keyboard", "touch"] do
    {:noreply, assign(socket, :interaction, "#{kind} input received")}
  end

  def handle_event("worker-ready", _params, socket), do: {:noreply, assign(socket, :worker_ready, true)}

  def handle_event("reduced-motion", %{"reduced" => reduced_motion}, socket) when is_boolean(reduced_motion) do
    {:noreply, assign(socket, :reduced_motion, reduced_motion)}
  end

  def handle_event("live-update", _params, socket) do
    {:noreply,
     socket
     |> assign(:fixture, Fixtures.live_updates().next)
     |> update(:graph_generation, &(&1 + 1))}
  end

  def handle_event("layout-mode", %{"mode" => "fallback"}, socket), do: {:noreply, assign(socket, :graph_layout_mode, :fallback)}
  def handle_event("layout-mode", %{"mode" => "worker"}, socket), do: {:noreply, assign(socket, :graph_layout_mode, :worker)}
  def handle_event("unmount-graph", _params, socket), do: {:noreply, assign(socket, :graph_mounted, false)}

  def handle_event("remount-graph", _params, socket) do
    {:noreply,
     socket
     |> assign(:graph_mounted, true)
     |> update(:graph_generation, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    counts = Fixtures.counts(assigns.fixture)
    assigns = assign(assigns, :counts, counts)

    ~H"""
    <main id="fixture-root" data-fixture-ready="true" data-mode={@mode} data-theme={@theme} aria-labelledby="fixture-title">
      <header>
        <h1 id="fixture-title">Synthetic LiveView browser fixture</h1>
        <p id="fixture-status" role="status">{@interaction}</p>
      </header>

      <nav aria-label="Fixture navigation">
        <button id="navigate-overview" type="button" phx-click="navigate" phx-value-view="overview" aria-current={if @view == :overview, do: "page"}>Overview</button>
        <button id="navigate-details" type="button" phx-click="navigate" phx-value-view="details" aria-current={if @view == :details, do: "page"}>Details</button>
      </nav>

      <section aria-labelledby="mode-title">
        <h2 id="mode-title">Synthetic mode</h2>
        <p id="mode-status">{@mode}</p>
      </section>

      <section aria-labelledby="input-title">
        <h2 id="input-title">Input paths</h2>
        <div class="controls">
          <button id="pointer-input" type="button" phx-click="input" phx-value-kind="pointer">Pointer input</button>
          <button id="keyboard-input" type="button" phx-click="input" phx-value-kind="keyboard">Keyboard input</button>
          <button id="touch-input" type="button" phx-click="input" phx-value-kind="touch">Touch input</button>
          <button id="theme-light" type="button" phx-click="set-theme" phx-value-theme="light">Light theme</button>
          <button id="theme-dark" type="button" phx-click="set-theme" phx-value-theme="dark">Dark theme</button>
          <button id="force-layout-fallback" type="button" phx-click="layout-mode" phx-value-mode="fallback">Force layout fallback</button>
          <button id="restore-layout-worker" type="button" phx-click="layout-mode" phx-value-mode="worker">Restore layout worker</button>
          <button id="unmount-graph" type="button" phx-click="unmount-graph">Unmount graph</button>
          <button id="remount-graph" type="button" phx-click="remount-graph">Remount graph</button>
        </div>
      </section>

      <section aria-labelledby="worker-title">
        <h2 id="worker-title">Worker and LiveView state</h2>
        <p id="worker-status" phx-hook="BrowserHarness" data-worker-ready={to_string(@worker_ready)} data-live-status="connected">Worker pending</p>
        <button id="live-update" type="button" phx-click="live-update">Apply synthetic update</button>
      </section>

      <section id="graph-viewport" tabindex="0" aria-label="Synthetic graph viewport" data-reduced-motion={to_string(@reduced_motion)}>
        <p>View: {@view}</p>
        <p id="fixture-counts">nodes: {@counts.nodes}, edges: {@counts.edges}, roots: {@counts.roots}</p>
        <div id="graph-content">
          <BuildOrderGraph.build_order_graph
            :if={@graph_mounted}
            id="fixture-build-order-graph"
            root_id="fixture-build-order-root"
            provider_generation={@graph_generation}
            dom_generation={@graph_generation}
            model={fixture_graph_model(@fixture)}
            adhoc={nil}
          />
          <p :if={!@graph_mounted} id="graph-unmounted" role="status">Graph unmounted</p>
        </div>
      </section>
    </main>
    """
  end

  # Build a real `BuildOrderViewModel` sized to the fixture so the redesigned
  # CSS-grid graph renders one semantic ticket card per member, distributed
  # across epic columns (lanes) × execution-wave rows (phases). The grid is
  # synchronous — there is no worker geometry to await — so the only synthetic
  # inputs the grid model needs are lane, phase, progress and status per card.
  @fixture_lanes ~w(dashboard-ui runtime plan-graph accounting)

  defp fixture_graph_model(fixture) do
    size = length(fixture.nodes)
    waves = fixture_wave_count(size)

    nodes =
      fixture.nodes
      |> Enum.with_index(1)
      |> Enum.map(fn {node, ordinal} -> fixture_node(node, ordinal, size, waves) end)

    node_ids = MapSet.new(nodes, & &1.card.identifier)

    edges =
      nodes
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {node, ordinal} ->
        target = "fixture-node-#{String.pad_leading(Integer.to_string(ordinal + waves), 3, "0")}"

        if MapSet.member?(node_ids, target),
          do: [fixture_edge(node.card.identifier, target, ordinal)],
          else: []
      end)

    %BuildOrderViewModel{
      status: :ready,
      root: %{identity: fixture_identity(0), generation: 1},
      nodes: nodes,
      edges: edges,
      generations: %{planning: 1, activity: 1}
    }
  end

  # A balanced ~sqrt(size) grid so both dimensions grow with the graph.
  defp fixture_wave_count(size), do: max(1, round(:math.sqrt(size)))

  defp fixture_node(node, ordinal, size, waves) do
    identifier = node.id
    identity = fixture_identity(ordinal)
    lane = Enum.at(@fixture_lanes, rem(ordinal - 1, min(length(@fixture_lanes), max(2, div(size, 20) + 2))))
    phase = rem(ordinal - 1, waves) + 1
    {status_key, status_text, progress} = fixture_status(ordinal)

    %Node{
      key: {:fixture, identifier},
      identity: identity,
      title: "Fixture #{ordinal}",
      url: "https://github.com/owner/repo/issues/#{ordinal}",
      plan: %{complexity: rem(ordinal - 1, 5) + 1},
      execution: %{},
      activity: %{},
      readiness: %{},
      lane_icon: nil,
      status_icon: %Icon{key: status_key, text: status_text},
      health: %{},
      observed_at: %{},
      provenance: %{},
      card: %{
        identifier: identifier,
        lane: lane,
        phase: phase,
        progress: progress,
        status_text: status_text
      }
    }
  end

  # Cycle four representative states so every wave carries mixed completion.
  defp fixture_status(ordinal) do
    case rem(ordinal, 4) do
      0 -> {:status_completed, "merged", 100}
      1 -> {:status_working, "agent live", 40}
      2 -> {:status_ready, "dependency-ready", 0}
      _ -> {:status_blocking, "blocked", 0}
    end
  end

  defp fixture_edge(source, target, ordinal) do
    state = if rem(ordinal, 2) == 0, do: :cleared, else: :blocking

    %Edge{
      id: "fixture-edge-#{ordinal}",
      source: fixture_identity(ordinal),
      target: fixture_identity(ordinal + 1),
      source_key: {:fixture, source},
      target_key: {:fixture, target},
      kind: :native,
      state: state,
      source_connection: :blocked_by,
      text: "Fixture relationship",
      diagnostics: []
    }
  end

  defp fixture_identity(number) do
    struct!(TrackerIdentity,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "NODE-owner-repo-#{number}",
      identifier: to_string(number),
      reason: nil
    )
  end
end

defmodule Aiur.BrowserHarness.TicketContextLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BuildOrder.Diagnostic
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{TicketContextAdapter, TicketContextSelection}
  alias AiurWeb.BuildOrder.TicketContextPresenter.{LogEntry, View}
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderTicketContext

  @observed_at ~U[2026-07-16 12:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:root_number, 100)
     |> assign(:generation, 7)
     |> assign(:members, [41, 42, 43])
     |> assign(:model, graph(100, 7, [41, 42, 43]))
     |> assign(:selection, TicketContextSelection.new(mount_epoch()))
     |> assign(:destinations_available?, true)
     |> assign(:stale_completion, nil)
     |> assign(:fixture_status, "Ticket context closed.")
     |> assign(:tick, 0)}
  end

  @impl true
  def handle_event("open-ticket-context", %{"member" => member}, socket) do
    selection = TicketContextSelection.open(socket.assigns.selection, socket.assigns.model, member)
    {:noreply, socket |> assign(:selection, selection) |> assign(:fixture_status, "Ticket context opened.")}
  end

  def handle_event("build-order-context-close", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection, TicketContextSelection.close(socket.assigns.selection))
     |> assign(:fixture_status, "Ticket context closed.")}
  end

  def handle_event("build-order-context-replace", %{"member" => member}, socket) do
    previous = completion(socket.assigns.selection)
    selection = TicketContextSelection.replace(socket.assigns.selection, socket.assigns.model, member)

    {:noreply,
     socket
     |> assign(:selection, selection)
     |> assign(:stale_completion, previous)
     |> assign(:fixture_status, "Relationship replacement applied.")}
  end

  def handle_event("build-order-context-back", _params, socket) do
    previous = completion(socket.assigns.selection)
    selection = TicketContextSelection.back(socket.assigns.selection, socket.assigns.model)

    {:noreply,
     socket
     |> assign(:selection, selection)
     |> assign(:stale_completion, previous)
     |> assign(:fixture_status, "Relationship back navigation applied.")}
  end

  def handle_event("fixture-generation", _params, socket) do
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, socket.assigns.members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Graph generation reconciled.")}
  end

  def handle_event("fixture-root", _params, socket) do
    root_number = socket.assigns.root_number + 100
    generation = socket.assigns.generation + 1
    model = graph(root_number, generation, socket.assigns.members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:root_number, root_number)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Build Order root changed.")}
  end

  def handle_event("fixture-remove-selected", _params, %{assigns: %{selection: %{selected: %TrackerIdentity{} = selected}}} = socket) do
    members = Enum.reject(socket.assigns.members, &(to_string(&1) == selected.identifier))
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Selected member removed.")}
  end

  def handle_event("fixture-remove-selected", _params, socket), do: {:noreply, socket}

  def handle_event("fixture-remove-upstream", _params, socket) do
    members = Enum.reject(socket.assigns.members, &(&1 == 41))
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Focused relationship removed.")}
  end

  def handle_event("fixture-remove-destination", _params, socket) do
    {:noreply,
     socket
     |> assign(:destinations_available?, false)
     |> assign(:fixture_status, "Focused destination removed.")}
  end

  def handle_event("fixture-stale-completion", _params, socket) do
    accepted? =
      case socket.assigns.stale_completion do
        %{token: token, identity: identity} -> TicketContextSelection.current_completion?(socket.assigns.selection, token, identity)
        _ -> false
      end

    status = if accepted?, do: "Stale completion applied.", else: "Stale completion rejected."
    {:noreply, assign(socket, :fixture_status, status)}
  end

  def handle_event("fixture-tick", _params, socket) do
    {:noreply, socket |> update(:tick, &(&1 + 1)) |> assign(:fixture_status, "Unrelated LiveView patch applied.")}
  end

  @impl true
  def render(assigns) do
    context = current_context(assigns.model, assigns.selection, assigns.destinations_available?)

    cards =
      Enum.map(assigns.model.nodes, fn node ->
        %{
          identity: node.identity,
          title: node.title,
          navigation: TicketContextSelection.navigation_value(assigns.model, node.identity),
          origin_id: TicketContextSelection.origin_id(assigns.model, node.identity)
        }
      end)

    assigns = assigns |> assign(:context, context) |> assign(:cards, cards)

    ~H"""
    <main class="app-shell" data-ticket-context-fixture="true">
      <header>
        <h1>Build Order ticket context fixture</h1>
        <p id="ticket-context-fixture-status" role="status">{@fixture_status}</p>
        <p id="ticket-context-fixture-generation">Root #{@root_number} · generation #{@generation} · tick #{@tick}</p>
      </header>

      <section aria-labelledby="ticket-context-fixture-cards">
        <h2 id="ticket-context-fixture-cards">Graph cards</h2>
        <div class="controls">
          <button
            :for={card <- @cards}
            id={card.origin_id}
            type="button"
            phx-click="open-ticket-context"
            phx-value-member={card.navigation}
            data-ticket-identifier={card.identity.identifier}
          >
            {card.title}
          </button>
        </div>
      </section>

      <div class="controls" aria-label="Ticket context fixture transitions">
        <button id="fixture-generation" type="button" phx-click="fixture-generation">Advance graph generation</button>
        <button id="fixture-root" type="button" phx-click="fixture-root">Switch Build Order root</button>
        <button id="fixture-remove-selected" type="button" phx-click="fixture-remove-selected">Remove selected member</button>
        <button id="fixture-remove-upstream" type="button" phx-click="fixture-remove-upstream">Remove upstream relationship</button>
        <button id="fixture-remove-destination" type="button" phx-click="fixture-remove-destination">Remove Chat destination</button>
        <button id="fixture-stale-completion" type="button" phx-click="fixture-stale-completion">Apply stale detail completion</button>
        <button id="fixture-tick" type="button" phx-click="fixture-tick">Apply unrelated patch</button>
      </div>

      <BuildOrderTicketContext.build_order_ticket_context
        :if={@context}
        id="fixture-ticket-context"
        context={@context}
        selection={@selection}
      />
    </main>
    """
  end

  defp current_context(model, %{status: :open, selected: %TrackerIdentity{} = selected}, destinations_available?) do
    model
    |> TicketContextAdapter.present(selected, base_context(selected), capabilities(selected, destinations_available?))
    |> case do
      %{status: :available} = context -> context
      _unavailable -> nil
    end
  end

  defp current_context(_model, _selection, _destinations_available?), do: nil

  defp base_context(%TrackerIdentity{} = identity) do
    {title, detail_state, history_state} = ticket_states(identity.identifier)

    %View{
      identity: identity,
      repository: "owner/repo",
      identifier: identity.identifier,
      title: title,
      description: "A bounded description for the browser fixture.",
      lifecycle: %{state: :open, reason: :none},
      detail: %{
        state: detail_state,
        observed_at: @observed_at,
        last_success_at: @observed_at,
        last_attempt_at: @observed_at
      },
      history: %{
        state: history_state,
        freshness: if(history_state == :stale, do: :stale, else: :fresh),
        observed_at: @observed_at,
        source_health: %{activity: :available, history: :available}
      },
      progress: %{
        status: :known,
        percent: 40,
        source: :checkin,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{run_id: "fixture"}
      },
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{}
      },
      logs: %{
        entries: [
          %LogEntry{
            kind: :progress,
            label: "Progress updated",
            source: :exchange,
            occurred_at: @observed_at,
            observed_at: @observed_at
          }
        ],
        truncated?: false,
        observed_at: @observed_at
      },
      capabilities: []
    }
  end

  defp ticket_states("41"), do: {"Upstream ticket", :available, :available}
  defp ticket_states("43"), do: {"Downstream ticket", :stale, :stale}
  defp ticket_states(_identifier), do: {"Configured ticket", :available, :available}

  defp capabilities(%TrackerIdentity{} = identity, false) do
    identity
    |> capabilities(true)
    |> Map.put(:chat, %{available?: false, identity: identity, reason: :stale})
  end

  defp capabilities(%TrackerIdentity{identifier: "43"} = identity, true) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: false, identity: identity, reason: :stale},
      commands: %{available?: false, identity: identity, reason: :unauthorized}
    }
  end

  defp capabilities(%TrackerIdentity{} = identity, true) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: true, destination: "/chat/#{identity.identifier}", identity: identity, active?: true, readable?: true},
      commands: %{available?: true, destination: "/decisions/#{identity.identifier}", identity: identity, readable?: true}
    }
  end

  defp mount_epoch, do: "ticket-context-mount-#{System.unique_integer([:positive, :monotonic])}"

  defp graph(root_number, generation, members) do
    nodes = Enum.map(members, &member/1)
    node_keys = MapSet.new(nodes, & &1.key)

    edges =
      [
        edge(identity(41), identity(42), :blocking, :native, []),
        edge(identity(42), identity(43), :terminal_unsatisfied, :native, []),
        edge(identity(9, owner: "other", repository: "repo", provider_id: "FOREIGN-9"), identity(42), :unknown, :external, [
          Diagnostic.new(:external_dependency)
        ]),
        edge(identity(8), identity(42), :unknown, :native, [Diagnostic.new(:unresolved_internal_dependency)])
      ]
      |> Enum.filter(&MapSet.member?(node_keys, &1.target_key))

    %BuildOrderViewModel{
      status: :ready,
      root: %{identity: identity(root_number), generation: generation},
      nodes: nodes,
      edges: edges,
      generations: %{planning: generation, activity: generation}
    }
  end

  defp member(number) do
    identity = identity(number)

    %Node{
      key: TrackerIdentity.github_key(identity),
      identity: identity,
      title: ticket_states(identity.identifier) |> elem(0),
      url: issue_url(identity),
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: readiness(number),
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      card: %{}
    }
  end

  defp edge(source, target, state, kind, diagnostics) do
    %Edge{
      id: "#{kind}-#{source.identifier || "missing"}-#{target.identifier || "missing"}",
      source: source,
      target: target,
      source_key: TrackerIdentity.github_key(source),
      target_key: TrackerIdentity.github_key(target),
      kind: kind,
      state: state,
      source_connection: :blocked_by,
      url: issue_url(source),
      text: "Controlled browser-fixture relationship",
      diagnostics: diagnostics
    }
  end

  defp readiness(42), do: :unknown
  defp readiness(43), do: :terminal_unsatisfied
  defp readiness(_number), do: :ready

  defp completion(%{status: :open, request_token: token, selected: %TrackerIdentity{} = identity}),
    do: %{token: token, identity: identity}

  defp completion(_selection), do: nil

  defp issue_url(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier}),
    do: "https://github.com/#{owner}/#{repository}/issues/#{identifier}"

  defp identity(number, overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "ISSUE-#{number}",
          identifier: to_string(number),
          reason: nil
        ],
        overrides
      )
    )
  end
end

defmodule Aiur.BrowserHarness.UnitsLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BrowserHarness.FixtureServer
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextPresenter.{Capability, View}

  alias AiurWeb.OperatorControlCenter.{
    ConversationDrawer,
    DecisionPath,
    TicketContext,
    UnitsFilters,
    UnitsPresenter,
    UnitsTable,
    UnitsURL
  }

  alias AiurWeb.OperatorControlCenter.ConversationDrawer.Presenter, as: ConversationPresenter

  @now ~U[2026-07-17 12:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:catalog, catalog(rows()))
     |> assign(:selection, UnitsURL.default_selection())
     |> assign(:now, @now)
     |> assign(:context, nil)
     |> assign(:conversation_drawer, nil)
     |> assign(:selected_row, nil)
     |> assign(:generation, 1)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :selection, UnitsURL.decode(params))}
  end

  @impl true
  def handle_event("select-units-scope", %{"scope" => scope}, socket) do
    selection = UnitsPresenter.select_scope(socket.assigns.selection, scope)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("toggle-units-condition", %{"condition" => condition}, socket) do
    selection = UnitsPresenter.toggle_condition(socket.assigns.selection, condition)
    {:noreply, push_patch(socket, to: units_path(selection))}
  end

  def handle_event("select-all-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_all_filters()))}
  end

  def handle_event("select-no-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsPresenter.select_no_filters()))}
  end

  def handle_event("reset-units-filters", _params, socket) do
    {:noreply, push_patch(socket, to: units_path(UnitsURL.zero_result_reset()))}
  end

  def handle_event("inspect-unit", %{"unit" => token}, socket) do
    case UnitsPresenter.lookup(socket.assigns.catalog, token) do
      {:ok, row} -> {:noreply, socket |> assign(:selected_row, row) |> assign(:context, context(row))}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  def handle_event("show-agent-log", _params, socket), do: {:noreply, socket}

  def handle_event("read-conversation", %{"unit" => token}, socket) do
    case UnitsPresenter.lookup(socket.assigns.catalog, token) do
      {:ok, row} ->
        drawer = %{
          origin_id: "units-conversation-#{token}",
          view: ConversationPresenter.present(row, conversation_snapshot())
        }

        {:noreply, assign(socket, :conversation_drawer, drawer)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("close-conversation", _params, socket), do: {:noreply, assign(socket, :conversation_drawer, nil)}

  def handle_event("close-ticket-context", _params, socket) do
    {:noreply, socket |> assign(:context, nil) |> assign(:selected_row, nil)}
  end

  def handle_event("same-identity-update", _params, socket) do
    catalog = update_catalog(socket.assigns.catalog, &update_primary_row/1)

    {:noreply,
     socket
     |> assign(:catalog, catalog)
     |> update(:generation, &(&1 + 1))}
  end

  def handle_event("remove-selected-unit", _params, socket) do
    selected = socket.assigns.selected_row

    catalog =
      update_catalog(socket.assigns.catalog, fn rows ->
        Enum.reject(rows, &same_identity?(Map.get(&1, :identity), selected && selected.identity))
      end)

    projected_ids =
      catalog
      |> UnitsPresenter.project(socket.assigns.selection)
      |> Map.get(:rows, [])
      |> Enum.map(& &1.identity.identifier)

    FixtureServer.set_streamdeck_snapshot_identities(projected_ids)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)

    {:noreply,
     socket
     |> assign(:catalog, catalog)
     |> update(:generation, &(&1 + 1))}
  end

  @impl true
  def render(assigns) do
    view = UnitsPresenter.project(assigns.catalog, assigns.selection)

    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:announcement, UnitsPresenter.announcement(view))

    ~H"""
    <main class="app-shell" data-units-fixture="true">
      <section class="section-card units-card" aria-labelledby="units-title">
        <header class="section-header units-header">
          <div>
            <p class="section-eyebrow">Current-run catalog</p>
            <h1 id="units-title" tabindex="-1">Units</h1>
            <p>{@view.total_count} observed · {@view.counts.scope} in selected scope</p>
          </div>
        </header>

        <p id="units-status" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {@announcement}
        </p>

        <UnitsFilters.units_filters
          selection={@selection}
          counts={@view.counts}
          count_status={@view.count_status}
        />
        <UnitsTable.units_table view={@view} now={@now} />
      </section>

      <div class="controls" aria-label="Units fixture updates">
        <button id="same-identity-update" type="button" phx-click="same-identity-update">Update same Unit</button>
        <button id="remove-selected-unit" type="button" phx-click="remove-selected-unit">Remove selected Unit</button>
      </div>

      <TicketContext.ticket_context
        :if={@context}
        id="units-fixture-ticket-context"
        context={@context}
        close_event="close-ticket-context"
        fallback_focus_id="units-title"
      />

      <ConversationDrawer.conversation_drawer
        :if={@conversation_drawer}
        id="units-fixture-conversation-drawer"
        view={@conversation_drawer.view}
        close_event="close-conversation"
        fallback_focus_id="units-title"
        origin_id={@conversation_drawer.origin_id}
      />
    </main>
    """
  end

  defp catalog(rows) do
    %{
      status: :ready,
      message: nil,
      snapshot: %{
        rows: rows,
        health: %{membership: :available},
        freshness: %{membership: %{status: :fresh}}
      }
    }
  end

  defp update_catalog(catalog, fun) do
    put_in(catalog, [:snapshot, :rows], fun.(catalog.snapshot.rows))
  end

  defp update_primary_row(rows) do
    Enum.map(rows, fn
      %{identity: %{identifier: "1110"}} = row ->
        row
        |> Map.put(:title, "Responsive Units interface · updated")
        |> Map.put(:progress, %{status: :known, percent: 60, source: :checkin, freshness: :fresh})

      row ->
        row
    end)
  end

  defp rows do
    [
      row(identity("NODE-1110", "1110"), %{
        title: "Responsive Units interface",
        lifecycle: :active,
        runtime: runtime(:running, :working, :active, 4_200),
        progress: %{status: :known, percent: 50, source: :checkin, freshness: :fresh},
        latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}},
        live_conversation: %{
          generation_handle: "conversation:" <> String.duplicate("a", 43),
          state: :live,
          health: :healthy,
          freshness: :current
        }
      }),
      row(identity("NODE-1111", "1111"), %{
        title: "Paused provider follow-up",
        lifecycle: :active,
        runtime: runtime(:running, :paused, :waiting_for_human, 900),
        reasons: reasons(:waiting_for_human, :waiting_for_human, :open_command, :operator_pause, nil),
        open_command_count: 1,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown}
      }),
      row(identity("NODE-1112", "1112"), %{
        title: "Queued integration",
        lifecycle: :queued,
        runtime: runtime(:retrying, :retrying, :backing_off, 0),
        reasons: reasons(:backing_off, nil, nil, nil, :backing_off),
        requested_model: nil,
        resolved_model: nil,
        effort: nil,
        complexity: nil,
        build_lane: nil,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown}
      }),
      row(identity("NODE-1113", "1113"), %{
        title: "Finished accessibility evidence",
        lifecycle: :terminal,
        terminal?: true,
        runtime: runtime(:idle, :completed, :none, 7_200),
        progress: %{status: :known, percent: 100, source: :phase, freshness: :stale},
        latest_evidence: %{status: :known, source: %{kind: :pull_request, name: "merged"}}
      })
    ] ++
      Enum.map(1114..1116, fn number ->
        row(identity("NODE-#{number}", to_string(number)), %{
          title: "Queued integration #{number}",
          lifecycle: :queued,
          runtime: runtime(:retrying, :retrying, :backing_off, 0),
          reasons: reasons(:backing_off, nil, nil, nil, :backing_off),
          requested_model: nil,
          resolved_model: nil,
          effort: nil,
          complexity: nil,
          build_lane: nil,
          progress: %{status: :unknown},
          latest_evidence: %{status: :unknown}
        })
      end)
  end

  defp conversation_snapshot do
    %{
      state: :live,
      health: :healthy,
      freshness: :current,
      messages: [
        %{
          id: "fixture-message",
          role: "agent",
          title: "Assistant",
          body: "Conversation drawer hook is running.",
          occurred_at: @now,
          observed_at: @now
        }
      ],
      observed_at: @now,
      truncated?: false,
      evicted_count: 0,
      source: %{worker_generation: 1, session_id: "fixture-session"}
    }
  end

  defp row(identity, overrides) do
    Map.merge(
      %{
        identity: identity,
        title: "Unit #{identity.identifier}",
        url: "https://github.com/its-everdred/aiur/issues/#{identity.identifier}",
        lifecycle: :active,
        terminal?: false,
        replacement_boundary?: false,
        tracker_state: "in-progress",
        backend: :codex,
        agent_family: :codex,
        requested_model: "gpt-5.6-terra",
        resolved_model: nil,
        effort: :high,
        complexity: 3,
        build_lane: "L2",
        reasons: reasons(:active, nil, nil, nil, nil),
        runtime: runtime(:running, :working, :active, 60),
        timestamps: %{started_at: "2026-07-17T11:00:00Z"},
        open_command_count: 0,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown},
        provider_health: %{
          membership: :available,
          status: :available,
          activity: :available,
          decisions: :available,
          issue: :available
        },
        field_sources: %{},
        sources: %{}
      },
      overrides
    )
  end

  defp runtime(bucket, work_state, waiting_reason, seconds) do
    %{
      bucket: bucket,
      work_state: work_state,
      waiting_reason: waiting_reason,
      tracker_paused?: work_state == :paused,
      runtime_seconds: seconds,
      stale_for_seconds: 0,
      membership_lifecycle: :active
    }
  end

  defp reasons(waiting, blocking, alert, pause, stuck) do
    %{waiting: waiting, blocking: blocking, alert: alert, pause: pause, stuck: stuck}
  end

  defp identity(provider_id, identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end

  defp context(row) do
    %View{
      identity: row.identity,
      repository: "its-everdred/aiur",
      identifier: row.identity.identifier,
      title: row.title,
      description: "Bounded ticket context from the accepted shared presentation.",
      lifecycle: %{state: :open, reason: :none},
      detail: %{state: :available, observed_at: @now, last_success_at: @now, last_attempt_at: @now},
      history: %{
        state: :available,
        freshness: :fresh,
        observed_at: @now,
        source_health: %{activity: :available, history: :available}
      },
      progress: Map.merge(%{occurred_at: @now, observed_at: @now, provenance: %{}}, row.progress),
      latest_evidence: Map.merge(%{occurred_at: @now, observed_at: @now, provenance: %{}}, row.latest_evidence),
      logs: %{entries: [], truncated?: false, observed_at: @now},
      capabilities: [
        %Capability{
          kind: :github,
          variant: :issue,
          label: "Issue",
          href: row.url,
          available?: true,
          external?: true
        },
        %Capability{kind: :chat, label: "Chat", available?: false, external?: false, reason: "Chat is unavailable."},
        %Capability{
          kind: :commands,
          label: "Commands",
          href: DecisionPath.inbox(:all, %{ticket: row.identity.identifier}),
          available?: true,
          external?: false
        }
      ]
    }
  end

  defp units_path(selection), do: "/units?" <> UnitsURL.encode(selection)

  defp same_identity?(%TrackerIdentity{} = left, %TrackerIdentity{} = right),
    do: TrackerIdentity.github_key(left) == TrackerIdentity.github_key(right)

  defp same_identity?(_left, _right), do: false
end

defmodule Aiur.BrowserHarness.FixtureAuth do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @access_modes ~w(read_only writable)

  def authenticate(conn, %{"mode" => mode}) when mode in @access_modes do
    conn
    |> put_session("fixture_access", mode)
    |> redirect(to: "/fixture")
  end

  def authenticate(conn, _params), do: send_resp(conn, 404, "unknown synthetic fixture access mode")

  def require_access(conn, _opts) do
    if get_session(conn, "fixture_access") in @access_modes do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(401, "synthetic fixture authentication required")
      |> halt()
    end
  end
end

defmodule Aiur.BrowserHarness.FixtureStreamdeckControl do
  @moduledoc """
  Lets one browser spec opt its own fixture server into a writable dashboard.

  Stream Deck key presses only reach the agent control facade when the
  dashboard is writable, so the operator-flow spec needs that gate open to
  prove a pause actually pauses. Every `run-browser-tests.mjs` invocation gets
  its own fixture server, so flipping it here cannot leak into another spec.
  """

  use Phoenix.Controller, formats: []

  import Plug.Conn

  alias Aiur.BrowserHarness.FixtureServer

  @modes %{"writable" => true, "read_only" => false}

  def configure(conn, %{"mode" => mode}) when is_map_key(@modes, mode) do
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, Map.fetch!(@modes, mode))
    FixtureServer.reset_streamdeck_pauses()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "streamdeck fixture control: #{mode}")
  end

  def configure(conn, _params), do: send_resp(conn, 404, "unknown streamdeck fixture control mode")
end

defmodule Aiur.BrowserHarness.FixtureAssets do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @asset_root Path.join(__DIR__, "assets")

  def health(conn, _params), do: send_resp(conn, 200, "synthetic fixture ready")

  def phoenix_html(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_html/phoenix_html.js")
  def phoenix(conn, _params), do: serve_embedded(conn, "/vendor/phoenix/phoenix.js")
  def phoenix_live_view(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")
  def ticket_context_dialog_hook(conn, _params), do: serve_embedded(conn, "/ticket-context-dialog-hook.js")
  def build_order_grid_hook(conn, _params), do: serve_embedded(conn, "/build-order-grid-hook.js")
  def time_brush_hook(conn, _params), do: serve_embedded(conn, "/time-brush-hook.js")
  def streamdeck_emulator_hook(conn, _params), do: serve_embedded(conn, "/streamdeck-emulator-hook.js")
  def harness(conn, _params), do: serve_file(conn, "browser_harness.js")
  def worker(conn, _params), do: serve_file(conn, "browser_worker.js")

  defp serve_embedded(conn, asset) do
    case AiurWeb.StaticAssets.fetch(asset) do
      {:ok, content_type, body} -> conn |> put_resp_content_type(content_type) |> send_resp(200, body)
      :error -> send_resp(conn, 404, "asset not found")
    end
  end

  defp serve_file(conn, filename) do
    body = File.read!(Path.join(@asset_root, filename))
    conn |> put_resp_content_type("application/javascript") |> send_resp(200, body)
  end
end

defmodule Aiur.BrowserHarness.BuildOrderDataSource do
  @behaviour AiurWeb.BuildOrder.DataSource

  alias Aiur.BuildOrder.{Catalog, Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity

  @repository {"owner", "repo"}
  @observed_at ~U[2026-07-17 12:00:00Z]

  @impl true
  def subscribe_catalog, do: :ok

  @impl true
  def unsubscribe_catalog(_repository), do: :ok

  @impl true
  def catalog do
    entries = [root(42, "Release dashboard"), RootSummary.new(%{}), root(43, "Stale planning lane")]

    %Snapshot{
      scope: :catalog,
      repository: @repository,
      authority_epoch: 1,
      generation: 3,
      data: Catalog.new(entries, health(3, :healthy)),
      health: health(3, :healthy)
    }
  end

  @impl true
  def subscribe_selected(_identity), do: :ok

  @impl true
  def unsubscribe_selected(_identity), do: :ok

  @impl true
  def selected(identity), do: selected_snapshot(identity)

  @impl true
  def demand(identity), do: selected_snapshot(identity)

  @impl true
  def release(_identity), do: :ok

  @impl true
  def subscribe_sources, do: :ok

  @impl true
  def load_sources do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 9, entries: [activity(identity(5))], diagnostics: %{}}
    }
  end

  @impl true
  def load_runtime_sources do
    %{
      execution: %{running: [], retrying: [], idle: []},
      activity: %{generation: 9, entries: [activity(identity(5))], diagnostics: %{}}
    }
  end

  @impl true
  def subscribe_context(_identity), do: :ok

  @impl true
  def unsubscribe_context(_identity), do: :ok

  @impl true
  def load_context(_identity),
    do: %{detail: {:error, :unavailable}, history: {:error, :unavailable}}

  defp selected_snapshot(%TrackerIdentity{identifier: "42"} = identity) do
    snapshot =
      %Snapshot{
        scope: {:selected, identity},
        repository: @repository,
        authority_epoch: 1,
        generation: 7,
        data: SelectedRoot.new(root(42, "Release dashboard"), graph_members(), health(7, :healthy)),
        health: health(7, :healthy)
      }

    {:ok, snapshot}
  end

  defp selected_snapshot(%TrackerIdentity{identifier: "43"} = identity) do
    snapshot =
      %Snapshot{
        scope: {:selected, identity},
        repository: @repository,
        authority_epoch: 1,
        generation: 8,
        data: SelectedRoot.new(root(43, "Stale planning lane"), [member(8, "Stale member")], health(8, :stale)),
        health: health(8, :stale)
      }

    {:ok, snapshot}
  end

  defp selected_snapshot(_identity), do: {:error, :unavailable}

  defp activity(identity) do
    %{
      identity: identity,
      status: :fresh,
      active_stage: :review,
      stage: %{status: :known, value: :review, freshness: :fresh, observed_at: @observed_at, event_id: 2},
      progress: %{
        status: :known,
        percent: 60,
        source: :checkin,
        freshness: :fresh,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        event_id: 3
      },
      provenance: %{},
      observed_at: @observed_at,
      retention: :current
    }
  end

  defp graph_members do
    one = member(1, "Completed dependency", state: "CLOSED", state_reason: "COMPLETED")
    two = member(2, "Open dependency")
    three = member(3, "Not-planned dependency", state: "CLOSED", state_reason: "NOT_PLANNED")
    four = member(4, "Unknown dependency", state: "CLOSED", state_reason: "DUPLICATE")

    five =
      member(5, "Readiness target",
        dependencies: [
          dependency(5, identity(1)),
          dependency(5, identity(2)),
          dependency(5, identity(3)),
          dependency(5, identity(4)),
          Dependency.new(identity(5), identity(9, {"other", "repo"}), "https://github.com/other/repo/issues/9")
        ]
      )

    six = member(6, "Cycle one", dependencies: [dependency(6, identity(7))])
    seven = member(7, "Cycle two", dependencies: [dependency(7, identity(6))])
    [one, two, three, four, five, six, seven]
  end

  defp member(number, title, opts \\ []) do
    lane = if number == 4, do: "unrecognized-lane", else: "dashboard-ui"

    Member.new(%{
      identity: identity(number),
      title: title,
      url: issue_url(number),
      state: Keyword.get(opts, :state, "OPEN"),
      state_reason: Keyword.get(opts, :state_reason),
      dependencies: Keyword.get(opts, :dependencies, []),
      labels: ["complexity:2", "phase:1", "build-lane:#{lane}"]
    })
  end

  defp dependency(configured_number, endpoint),
    do: Dependency.new(identity(configured_number), endpoint, issue_url(endpoint.identifier))

  defp root(number, title) do
    RootSummary.new(%{
      identity: identity(number),
      title: title,
      url: issue_url(number),
      state: "OPEN",
      state_reason: nil
    })
  end

  defp identity(number, repository \\ @repository) do
    {owner, name} = repository

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: name,
      provider_id: "NODE-#{owner}-#{name}-#{number}",
      database_id: number,
      identifier: to_string(number),
      reason: nil
    }
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"

  defp health(generation, state) do
    ProviderHealth.new(generation, state, state == :healthy,
      observed_at: @observed_at,
      last_success_at: @observed_at
    )
  end
end

defmodule Aiur.BrowserHarness.ProviderMetersLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.OperatorControlCenter.{ProviderMeters, ProviderMetersPresenter}

  @observed ~U[2026-07-18 11:30:00Z]
  @reset ~U[2026-07-18 12:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :capability, %{state: :authorized, version: 1})}
  end

  @impl true
  def handle_event("lock", _params, socket) do
    {:noreply, assign(socket, :capability, AiurWeb.FinancialDataAccess.locked_capability())}
  end

  def handle_event("unlock", _params, socket) do
    {:noreply, assign(socket, :capability, %{state: :authorized, version: 1})}
  end

  @impl true
  def render(assigns) do
    view = ProviderMetersPresenter.present(assigns.capability, snapshots())

    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:announcement, ProviderMetersPresenter.announcement(view))

    ~H"""
    <main class="app-shell" data-provider-meters-fixture="true">
      <h1 class="sr-only">Provider meters fixture</h1>
      <ProviderMeters.provider_meters view={@view} announcement={@announcement} />

      <div class="controls" aria-label="Provider meter fixture updates">
        <button id="lock-provider-meters" type="button" phx-click="lock">Lock provider meters</button>
        <button id="unlock-provider-meters" type="button" phx-click="unlock">Unlock provider meters</button>
      </div>
    </main>
    """
  end

  defp snapshots do
    %{codex: codex(), claude: ProviderMeterSnapshot.unknown(:claude, :app_server)}
  end

  defp codex do
    %ProviderMeterSnapshot{
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "fixture-codex-generation",
      auth_mode: :subscription,
      plan: %{tier: :pro, source: :provider, observed_at: @observed, freshness: :fresh},
      observed_at: @observed,
      ingested_at: @observed,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: @observed, last_source_version: 1},
      windows: %{
        "primary" => %{
          kind: :rate_limit,
          name: "Primary",
          standing: :allowed,
          used_percent: 40,
          remaining_percent: 60,
          coverage: :supported,
          freshness: :fresh,
          resets_at: @reset,
          source: :codex_app_server
        },
        "credits" => %{kind: :credit, name: "Credits", coverage: :unsupported, standing: nil, used_percent: nil, source: :codex_app_server}
      }
    }
  end
end

defmodule Aiur.BrowserHarness.FixtureRouter do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  alias Aiur.BrowserHarness.FixtureAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :fixture_access do
    plug(:require_fixture_access)
  end

  pipeline :fixture_asset_access do
    plug(:require_fixture_or_dashboard_access)
  end

  scope "/" do
    get("/health", Aiur.BrowserHarness.FixtureAssets, :health)
    get("/assets/phoenix_html.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_html)
    get("/assets/phoenix.js", Aiur.BrowserHarness.FixtureAssets, :phoenix)
    get("/assets/phoenix_live_view.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_live_view)
    get("/assets/ticket-context-dialog-hook.js", Aiur.BrowserHarness.FixtureAssets, :ticket_context_dialog_hook)
    get("/assets/build-order-grid-hook.js", Aiur.BrowserHarness.FixtureAssets, :build_order_grid_hook)
    get("/assets/time-brush-hook.js", Aiur.BrowserHarness.FixtureAssets, :time_brush_hook)
    get("/assets/streamdeck-emulator-hook.js", Aiur.BrowserHarness.FixtureAssets, :streamdeck_emulator_hook)
    get("/assets/browser_harness.js", Aiur.BrowserHarness.FixtureAssets, :harness)
    get("/assets/browser_worker.js", Aiur.BrowserHarness.FixtureAssets, :worker)
  end

  scope "/" do
    pipe_through(:browser)

    get("/auth/:mode", Aiur.BrowserHarness.FixtureAuth, :authenticate)
    get("/streamdeck-control/:mode", Aiur.BrowserHarness.FixtureStreamdeckControl, :configure)
  end

  scope "/" do
    pipe_through([:browser, :fixture_access])

    live("/fixture", Aiur.BrowserHarness.FixtureLive, :index)
    live("/ticket-context", Aiur.BrowserHarness.TicketContextLive, :index)
    live("/units", Aiur.BrowserHarness.UnitsLive, :index)
    live("/provider-meters", Aiur.BrowserHarness.ProviderMetersLive, :index)
    live("/", Aiur.BrowserHarness.RouteShellLive, :index)
    live("/decisions", Aiur.BrowserHarness.RouteShellLive, :decisions)
    live("/decisions/:decision_id", Aiur.BrowserHarness.RouteShellLive, :decision)
  end

  scope "/" do
    pipe_through([:browser, :fixture_asset_access])

    get("/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css)
    get("/aiur-logo.png", AiurWeb.StaticAssetController, :aiur_logo)
  end

  # Route vendor assets through the production router so browser tests exercise
  # the same authenticated controller and content-addressed paths as a release.
  scope "/" do
    forward("/", AiurWeb.Router)
  end

  defp require_fixture_access(conn, opts), do: FixtureAuth.require_access(conn, opts)

  defp require_fixture_or_dashboard_access(conn, opts) do
    if Plug.Conn.get_session(conn, "fixture_access") in ~w(read_only writable),
      do: conn,
      else: AiurWeb.Router.dashboard_basic_auth(conn, opts)
  end
end

defmodule Aiur.BrowserHarness.FixtureEndpoint do
  use Phoenix.Endpoint, otp_app: :aiur

  @session_options [store: :cookie, key: "_aiur_browser_harness", signing_salt: "browser-harness", http_only: true, same_site: "Lax"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]], longpoll: false)

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.revalidated_static_paths(),
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
  )

  plug(Plug.Static,
    at: "/",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.long_lived_static_paths(),
    cache_control_for_etags: "public, max-age=31536000",
    cache_control_for_vsn_requests: "public, max-age=31536000"
  )

  plug(Plug.Static,
    at: "/provider-assets",
    from: :aiur,
    gzip: false,
    only: AiurWeb.StaticAssets.provider_asset_paths(),
    cache_control_for_etags: "private, max-age=0, must-revalidate",
    cache_control_for_vsn_requests: "private, max-age=0, must-revalidate"
  )

  plug(Plug.RequestId)
  plug(Plug.Session, @session_options)
  plug(Aiur.BrowserHarness.FixtureRouter)
end

defmodule Aiur.BrowserHarness.FixtureServer do
  alias Aiur.BrowserHarness.FixtureEndpoint
  alias Aiur.IssueLog

  @port System.fetch_env!("AIUR_BROWSER_PORT") |> String.to_integer()

  def run do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    System.put_env("AIUR_DASHBOARD_USERNAME", "browser_fixture")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "browser_fixture_password")
    Application.put_env(:aiur, :workflow_file_path, Path.expand("../fixtures/test.aiurconfig", __DIR__))
    Application.put_env(:aiur, :build_order_data_source, Aiur.BrowserHarness.BuildOrderDataSource)
    configure_forwarded_dashboard()

    {:ok, _} =
      Supervisor.start_link(
        [
          Supervisor.child_spec(
            {Phoenix.PubSub, name: Aiur.BrowserHarness.FixturePubSub},
            id: Aiur.BrowserHarness.FixturePubSub
          ),
          Supervisor.child_spec({Phoenix.PubSub, name: Aiur.PubSub}, id: Aiur.PubSub),
          {AiurWeb.Endpoint, []},
          AiurWeb.FinancialDataAccess.Generation
        ],
        strategy: :one_for_one
      )

    Application.put_env(
      :aiur,
      Aiur.BrowserHarness.FixtureEndpoint,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: @port],
      url: [host: "127.0.0.1", port: @port],
      secret_key_base: String.duplicate("b", 64),
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: Aiur.BrowserHarness.FixturePubSub,
      live_view: [signing_salt: "browser-harness-live-view"],
      check_origin: false
    )

    {:ok, _} = FixtureEndpoint.start_link()
    IO.puts("Aiur browser harness fixture ready at http://127.0.0.1:#{@port}")
    Process.sleep(:infinity)
  end

  def set_streamdeck_snapshot_identities(identifiers) when is_list(identifiers) do
    :persistent_term.put({__MODULE__, :streamdeck_snapshot_identities}, Enum.map(identifiers, &to_string/1))
  end

  @doc """
  Fixture stand-in for `AgentChat.pause/1` and `AgentChat.resume/1`.

  The emulator's key press is only meaningful if the fleet it renders actually
  moves, so the fixture records the operator pause and republishes the fleet.
  The next projection buckets the agent as `:paused`, exactly as the real
  orchestrator snapshot would.
  """
  def streamdeck_pause(identifier), do: {:ok, set_streamdeck_paused(identifier, true)}

  def streamdeck_resume(identifier), do: {:ok, set_streamdeck_paused(identifier, false)}

  @doc "Drops every recorded operator pause so a spec starts from the seeded fleet."
  def reset_streamdeck_pauses do
    :persistent_term.put({__MODULE__, :streamdeck_paused}, MapSet.new())
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)
    :ok
  end

  defp set_streamdeck_paused(identifier, paused?) do
    identifier = to_string(identifier)
    current = :persistent_term.get({__MODULE__, :streamdeck_paused}, MapSet.new())
    updated = if paused?, do: MapSet.put(current, identifier), else: MapSet.delete(current, identifier)

    :persistent_term.put({__MODULE__, :streamdeck_paused}, updated)
    Phoenix.PubSub.broadcast(Aiur.PubSub, "streamdeck:fixture", :streamdeck_fixture_fleet_changed)

    identifier
  end

  defp streamdeck_paused?(identifier) do
    MapSet.member?(:persistent_term.get({__MODULE__, :streamdeck_paused}, MapSet.new()), to_string(identifier))
  end

  def streamdeck_snapshot do
    case :persistent_term.get({__MODULE__, :streamdeck_snapshot_identities}, nil) do
      identifiers when is_list(identifiers) ->
        streamdeck_snapshot(identifiers)

      _ ->
        # The canonical bucket order puts the alert agent first, so the LiveView
        # initially focuses 1331; seed its durable feed so the production
        # AgentEventFeed path has real content to project in logs mode.
        write_feed_if_missing("1331")
        # The operator flow drives one agent through cmd and logs, so the
        # running agent it controls needs a durable feed of its own.
        write_feed_if_missing("1352")

        %{
          running: [streamdeck_agent("1352", "Fixture running", "codex", progress_percent: 0)],
          retrying: [streamdeck_agent("1338", "Fixture stuck", "codex", work_state: :error, progress_percent: 100)],
          idle: [
            streamdeck_agent("1345", "Fixture paused", "claude", work_state: :paused),
            streamdeck_agent("1350", "Fixture queued", "codex", waiting_reason: :waiting_for_dependency),
            streamdeck_agent("1331", "Fixture alert", "claude", open_decision_count: 1),
            streamdeck_agent("1360", "Fixture extra 1", "codex"),
            streamdeck_agent("1361", "Fixture extra 2", "codex"),
            streamdeck_agent("1362", "Fixture extra 3", "codex"),
            streamdeck_agent("1363", "Fixture extra 4", "codex"),
            streamdeck_agent("1366", "Fixture extra 5", "codex"),
            streamdeck_agent("1367", "Fixture extra 6", "codex"),
            streamdeck_agent("1370", "Fixture extra 7", "codex"),
            streamdeck_agent("1371", "Fixture extra 8", "codex"),
            streamdeck_agent("1372", "Fixture extra 9", "codex"),
            streamdeck_agent("1373", "Fixture extra 10", "codex"),
            streamdeck_agent("1374", "Fixture extra 11", "codex"),
            streamdeck_agent("1375", "Fixture extra 12", "codex"),
            streamdeck_agent("1376", "Fixture extra 13", "codex"),
            streamdeck_agent("1377", "Fixture extra 14", "codex")
          ]
        }
    end
  end

  defp streamdeck_snapshot(identifiers) when is_list(identifiers) do
    agents =
      Enum.map(identifiers, fn identifier ->
        streamdeck_agent(identifier, "Unit #{identifier}", "codex")
      end)

    if agents != [], do: write_feed_if_missing(hd(identifiers))

    %{running: Enum.take(agents, 1), retrying: [], idle: Enum.drop(agents, 1)}
  end

  def streamdeck_provider_meters do
    %{
      "claude" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 30, "remaining" => "22m", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 47, "resets_at" => "2026-08-13T18:00:00Z", "freshness" => "fresh"}
        }
      },
      "codex" => %{
        "state" => "observed",
        "windows" => %{
          "session" => %{"kind" => "rate_limit", "used_percent" => 50, "remaining" => "1h", "freshness" => "fresh"},
          "weekly" => %{"kind" => "rate_limit", "used_percent" => 75, "resets_at" => "2026-08-14T20:00:00Z", "freshness" => "fresh"}
        }
      }
    }
  end

  # Seeded once per harness boot, not once per disk lifetime. `File.exists?/1`
  # alone made the feed sticky: a local run reused whatever a previous run had
  # written, so editing this fixture silently had no effect on the tests that
  # read it. The snapshot callbacks fire on every poll, hence the guard.
  defp write_feed_if_missing(identifier) when is_binary(identifier) do
    key = {__MODULE__, :seeded_feed, identifier}

    if :persistent_term.get(key, false) do
      :ok
    else
      write_feed(IssueLog.transcript_path(identifier))
      :persistent_term.put(key, true)
    end
  end

  defp write_feed(path) do
    File.mkdir_p!(Path.dirname(path))

    # A mix of roles, not ten assistants: the roles are what `AgentEventFeed`
    # maps onto the five Stream Deck direction badges, so a single-role feed
    # would let a log key assert its badge without the mapping being wired at
    # all. Events 1..5 cover AGENT, CONSUME, SYSTEM, INFO and EMIT in order.
    roles = %{1 => "assistant", 2 => "user", 3 => "system", 4 => "reasoning", 5 => "command"}

    events =
      Enum.map(10..1, fn index ->
        %{
          "role" => Map.get(roles, index, "assistant"),
          "body" => "event-#{index}",
          "timestamp" => "2026-08-02T00:00:00Z",
          "msg_id" => nil,
          "sequence" => index,
          "turn_id" => "fixture-#{index}",
          "payload" => nil
        }
      end)

    File.write!(path, Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp configure_forwarded_dashboard do
    config =
      :aiur
      |> Application.get_env(AiurWeb.Endpoint, [])
      |> Keyword.merge(
        server: false,
        # Stays read-only by default so incidental key presses in other specs
        # cannot mutate the shared fixture fleet. The operator-flow spec opts its
        # own fixture server in through `/streamdeck-control/writable`.
        dashboard_writable: false,
        control_center_cache: false,
        snapshot_timeout_ms: 100,
        streamdeck_fixture_fleet: true,
        streamdeck_snapshot_fun: &__MODULE__.streamdeck_snapshot/0,
        streamdeck_provider_meters_fun: &__MODULE__.streamdeck_provider_meters/0,
        agent_chat_pause_fun: &__MODULE__.streamdeck_pause/1,
        agent_chat_resume_fun: &__MODULE__.streamdeck_resume/1
      )
      |> Keyword.delete(:streamdeck_logs_fun)

    Application.put_env(:aiur, AiurWeb.Endpoint, config)
  end

  defp streamdeck_agent(identifier, title, backend, attrs \\ []) do
    %{
      identifier: identifier,
      title: title,
      backend: backend,
      work_state: :working,
      open_decision_count: 0,
      waiting_reason: :active,
      tracker_paused: false,
      progress_percent: 50,
      priority: nil
    }
    |> Map.merge(Map.new(attrs))
    |> apply_operator_pause(identifier)
  end

  # An operator pause outranks the seeded work state so a key press moves the
  # agent into the paused bucket without the fixture restating every field.
  defp apply_operator_pause(agent, identifier) do
    if streamdeck_paused?(identifier), do: Map.put(agent, :tracker_paused, true), else: agent
  end
end

Aiur.BrowserHarness.FixtureServer.run()
