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
        <script defer src="/assets/ticket-context-dialog-hook.js"></script>
        <script defer src="/assets/browser_harness.js"></script>
        <link rel="stylesheet" href="/dashboard.css" />
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
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

  alias AiurWeb.OperatorControlCenter.{DashboardShell, RouteRegistry}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:analytics, analytics(%{}))
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:analytics, analytics(params))
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <DashboardShell.dashboard_shell
        route={@current_route}
        routes={RouteRegistry.routes(@analytics)}
        now={~U[2026-07-15 12:00:00Z]}
        tracker_kind="fixture"
        agent_kind="fixture"
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
    {:noreply, assign(socket, :view, view)}
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
            nodes={graph_nodes(@fixture)}
            edges={graph_edges(@fixture)}
            layout_assets={layout_assets(@graph_layout_mode)}
          />
          <p :if={!@graph_mounted} id="graph-unmounted" role="status">Graph unmounted</p>
        </div>
      </section>
    </main>
    """
  end

  defp graph_nodes(fixture) do
    Enum.map(fixture.nodes, fn node ->
      ordinal = node.ordinal || 1

      %{
        id: node.id,
        title: "Fixture #{ordinal}",
        summary: "Semantic card #{ordinal}",
        lane: rem(ordinal - 1, 2),
        phase: rem(div(ordinal - 1, 2), 4)
      }
    end)
  end

  defp graph_edges(fixture) do
    states = [:cleared, :blocking, :terminal_unsatisfied, :unknown, :cyclic]

    edges =
      fixture.edges
      |> Enum.with_index()
      |> Enum.map(fn {_edge, index} ->
        source = Enum.at(fixture.nodes, rem(index, 2)).id
        target = Enum.at(fixture.nodes, index + 1).id

        %{id: "fixture-edge-#{index + 1}", source: source, target: target, state: Enum.at(states, rem(index, length(states)))}
      end)

    [%{id: "fixture-missing-endpoint", source: "missing:fixture-node", target: "fixture-node-001", state: :unknown} | edges]
  end

  defp layout_assets(:fallback), do: %{client: "", worker: "", engine: ""}
  defp layout_assets(:worker), do: nil
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
     |> assign(:selection, TicketContextSelection.new())
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
    context = current_context(assigns.model, assigns.selection)

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

  defp current_context(model, %{status: :open, selected: %TrackerIdentity{} = selected}) do
    model
    |> TicketContextAdapter.present(selected, base_context(selected), capabilities(selected))
    |> case do
      %{status: :available} = context -> context
      _unavailable -> nil
    end
  end

  defp current_context(_model, _selection), do: nil

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

  defp capabilities(%TrackerIdentity{identifier: "43"} = identity) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: false, identity: identity, reason: :stale},
      commands: %{available?: false, identity: identity, reason: :unauthorized}
    }
  end

  defp capabilities(%TrackerIdentity{} = identity) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: true, destination: "/chat/#{identity.identifier}", identity: identity, active?: true, readable?: true},
      commands: %{available?: true, destination: "/decisions/#{identity.identifier}", identity: identity, readable?: true}
    }
  end

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

defmodule Aiur.BrowserHarness.FixtureAssets do
  use Phoenix.Controller, formats: []

  import Plug.Conn

  @asset_root Path.join(__DIR__, "assets")

  def health(conn, _params), do: send_resp(conn, 200, "synthetic fixture ready")

  def phoenix_html(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_html/phoenix_html.js")
  def phoenix(conn, _params), do: serve_embedded(conn, "/vendor/phoenix/phoenix.js")
  def phoenix_live_view(conn, _params), do: serve_embedded(conn, "/vendor/phoenix_live_view/phoenix_live_view.js")
  def ticket_context_dialog_hook(conn, _params), do: serve_embedded(conn, "/ticket-context-dialog-hook.js")
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

  scope "/" do
    get("/health", Aiur.BrowserHarness.FixtureAssets, :health)
    get("/assets/phoenix_html.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_html)
    get("/assets/phoenix.js", Aiur.BrowserHarness.FixtureAssets, :phoenix)
    get("/assets/phoenix_live_view.js", Aiur.BrowserHarness.FixtureAssets, :phoenix_live_view)
    get("/assets/ticket-context-dialog-hook.js", Aiur.BrowserHarness.FixtureAssets, :ticket_context_dialog_hook)
    get("/assets/browser_harness.js", Aiur.BrowserHarness.FixtureAssets, :harness)
    get("/assets/browser_worker.js", Aiur.BrowserHarness.FixtureAssets, :worker)
  end

  scope "/" do
    pipe_through(:browser)

    get("/auth/:mode", Aiur.BrowserHarness.FixtureAuth, :authenticate)
  end

  scope "/" do
    pipe_through([:browser, :fixture_access])

    live("/fixture", Aiur.BrowserHarness.FixtureLive, :index)
    live("/ticket-context", Aiur.BrowserHarness.TicketContextLive, :index)
    live("/", Aiur.BrowserHarness.RouteShellLive, :index)
    live("/decisions", Aiur.BrowserHarness.RouteShellLive, :decisions)
    live("/decisions/:decision_id", Aiur.BrowserHarness.RouteShellLive, :decision)
    get("/dashboard.css", AiurWeb.StaticAssetController, :dashboard_css)
    get("/aiur-logo.png", AiurWeb.StaticAssetController, :aiur_logo)
  end

  # Route vendor assets through the production router so browser tests exercise
  # the same authenticated controller and content-addressed paths as a release.
  scope "/" do
    forward("/", AiurWeb.Router)
  end

  defp require_fixture_access(conn, opts), do: FixtureAuth.require_access(conn, opts)
end

defmodule Aiur.BrowserHarness.FixtureEndpoint do
  use Phoenix.Endpoint, otp_app: :aiur

  @session_options [store: :cookie, key: "_aiur_browser_harness", signing_salt: "browser-harness", http_only: true, same_site: "Lax"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]], longpoll: false)

  plug(Plug.RequestId)
  plug(Plug.Session, @session_options)
  plug(Aiur.BrowserHarness.FixtureRouter)
end

defmodule Aiur.BrowserHarness.FixtureServer do
  alias Aiur.BrowserHarness.FixtureEndpoint

  @port System.fetch_env!("AIUR_BROWSER_PORT") |> String.to_integer()

  def run do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)

    System.put_env("AIUR_DASHBOARD_USERNAME", "browser_fixture")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "browser_fixture_password")

    {:ok, _} =
      Supervisor.start_link(
        [
          {Phoenix.PubSub, name: Aiur.BrowserHarness.FixturePubSub},
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
end

Aiur.BrowserHarness.FixtureServer.run()
