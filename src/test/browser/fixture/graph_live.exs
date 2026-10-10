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
