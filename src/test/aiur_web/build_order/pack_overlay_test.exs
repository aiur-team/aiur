defmodule AiurWeb.BuildOrder.PackOverlayTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  alias Aiur.BuildOrder.{Catalog, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{ContextRuntime, DataSource, PackOverlay, RouteState, SourceRuntime}
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.{BuildOrderGraph, BuildOrderGridModel}

  defmodule Projection do
    def catalog, do: Process.get(:live_catalog)
    def selected(_identity), do: {:ok, Process.get(:live_selected)}
    def demand(identity), do: selected(identity)
    def refresh(identity), do: send(self(), {:refresh, identity})
  end

  setup do
    directory = Aiur.TestSupport.tmp_root!("production-pack-overlay")
    File.mkdir_p!(directory)

    pack = %{
      "build_order_id" => "acme/widgets:program",
      "repository" => "acme/widgets",
      "root_number" => 99,
      "title" => "Full program",
      "workstreams" => [%{"id" => "core", "title" => "Kernel epic"}],
      "phases" => [%{"phase" => 0, "title" => "Foundation phase"}],
      "external_gates" => [%{"id" => "DESIGN", "title" => "Owner design", "owner" => "Owner", "blocks" => 2}],
      "tickets" => [ticket("T1", 10), Map.put(ticket("T2", nil), "depends_on", ["T1"])]
    }

    path = Path.join(directory, "build-order.json")
    File.write!(path, Jason.encode!(pack))
    keys = [:build_order_planning_pack, :build_order_planning_membership_snapshot, :build_order_pack_status_health_snapshot, :build_order_data_source]
    previous = Map.new(keys, &{&1, Application.get_env(:aiur, &1)})
    Application.put_env(:aiur, :build_order_planning_pack, path)
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 1, members: []} end)
    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn -> health() end)
    Application.delete_env(:aiur, :build_order_data_source)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> if is_nil(value), do: Application.delete_env(:aiur, key), else: Application.put_env(:aiur, key, value) end)
      File.rm_rf(directory)
    end)

    root = RootSummary.new(%{identity: identity(99), title: "Live root", url: url(99), labels: ["build-order"], member_count: 1})

    member =
      Member.new(%{identity: identity(10), title: "Live promoted title", url: url(10), state: "CLOSED", state_reason: "COMPLETED", labels: ["phase:invalid", "build-lane:other", "complexity:3"]})

    catalog = %Snapshot{scope: :catalog, data: Catalog.new([root], health()), generation: 3, authority_epoch: 77, repository: {"acme", "widgets"}, health: health()}
    selected = %{catalog | scope: {:selected, root.identity}, data: SelectedRoot.new(root, [member], health())}
    Process.put(:live_catalog, catalog)
    Process.put(:live_selected, selected)
    %{path: path, pack: pack, root: root, selected: selected, catalog: catalog}
  end

  test "production DataSource renders live promoted and draft members with pack phases and epics", %{root: root} do
    assert Application.get_env(:aiur, :build_order_data_source, DataSource) == DataSource
    catalog = DataSource.catalog(graph_projection: Projection)
    assert [%{title: "Full program", member_count: 2, identity: root_identity}] = catalog.data.entries
    assert root_identity == root.identity
    {:ok, selected} = DataSource.demand(root.identity, graph_projection: Projection)
    assert selected.authority_epoch == 77
    assert [promoted, draft] = selected.data.members
    assert promoted.identity == identity(10)
    assert promoted.lifecycle.state == :closed
    assert promoted.title == "Live promoted title"
    assert promoted.metadata.phase == 0
    assert promoted.metadata.lane == "core"
    assert draft.draft?
    assert hd(draft.dependencies).identity == promoted.identity
    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.edges) == 1
    html = render_graph(selected, model)
    assert html =~ "Live promoted title"
    assert html =~ "Draft T2"
    assert html =~ "Kernel epic"
    assert html =~ "Foundation phase"
    assert html =~ "Owner design"
    refute html =~ "Phase label is invalid"
    assert length(Floki.find(Floki.parse_fragment!(html), "[data-bo-card]")) == 2
  end

  test "a cold production pack demands the live read even while drafts render", %{selected: selected, root: root} do
    Process.put(:live_selected, %{selected | data: nil, generation: :unknown})
    assert {:ok, combined} = DataSource.demand(root.identity, graph_projection: Projection)
    assert length(combined.data.members) == 2
    assert is_integer(combined.generation)
    assert_receive {:refresh, identity}, 1_000
    assert identity == root.identity
  end

  test "stale GitHub lifecycle cannot pose as current pack state", %{selected: selected, root: root} do
    stale_health = %{health() | state: :stale, complete?: false, failure: :timeout, observed_at: ~U[2026-01-01 00:00:00Z]}
    Process.put(:live_selected, %{selected | health: stale_health})
    {:ok, combined} = DataSource.selected(root.identity, graph_projection: Projection)
    assert combined.health.state == :healthy
    assert combined.github_health == stale_health
    assert hd(combined.data.members).lifecycle.state == :unknown
    assert hd(combined.data.members).identity == identity(10)
    assert length(combined.data.members) == 2
  end

  test "published GitHub snapshots retain drafts and refresh promoted lifecycle", %{catalog: catalog, selected: selected, root: root} do
    state = RouteState.new("overlay")
    {state, _effects} = RouteState.navigate(state, "99")
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    socket = socket |> SourceRuntime.initialize(DataSource) |> ContextRuntime.initialize("overlay") |> Phoenix.Component.assign(:route_state, state)
    socket = SourceRuntime.accept_projection(socket, catalog)
    socket = SourceRuntime.accept_projection(socket, selected)
    assert length(socket.assigns.model.nodes) == 2
    member = hd(selected.data.members)
    next = %{selected | generation: 4, data: %{selected.data | members: [%{member | lifecycle: Aiur.BuildOrder.Lifecycle.from_github("OPEN", nil)}]}}
    socket = SourceRuntime.accept_projection(socket, next)
    snapshot = RouteState.selected_snapshot(socket.assigns.route_state)
    assert length(snapshot.data.members) == 2
    assert hd(snapshot.data.members).lifecycle.state == :open
    assert snapshot.data.root.identity == root.identity
  end

  test "collapsed epic removes its cards while retaining counts and phase labels", %{root: root} do
    {:ok, selected} = DataSource.selected(root.identity, graph_projection: Projection)
    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    html = render_graph(selected, model, ["core"])
    assert html =~ "Expand Kernel epic"
    assert html =~ "aria-expanded=\"false\""
    assert html =~ "Foundation phase"
    assert Floki.find(Floki.parse_fragment!(html), "[data-bo-card]") == []
    assert length(model.nodes) == 2
  end

  test "650 members render and collapse without dropping the source graph", %{path: path, pack: pack, root: root} do
    tickets = Enum.map(1..650, &ticket("T#{&1}", if(&1 == 1, do: 10, else: nil)))
    File.write!(path, Jason.encode!(%{pack | "tickets" => tickets}))
    {:ok, selected} = DataSource.selected(root.identity, graph_projection: Projection)
    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert length(model.nodes) == 650
    grid = BuildOrderGridModel.build(model, nil)
    assert Enum.map(grid.waves, & &1.phase) == [0]
    html = render_graph(selected, model)
    assert length(Floki.find(Floki.parse_fragment!(html), "[data-bo-card]")) == 650
    assert Floki.find(Floki.parse_fragment!(render_graph(selected, model, ["core"])), "[data-bo-card]") == []
  end

  test "pack removal refreshes catalog and selected drafts without waiting for a GitHub generation", %{path: path, root: root} do
    first = DataSource.catalog(graph_projection: Projection)
    {:ok, selected} = DataSource.selected(root.identity, graph_projection: Projection)
    {state, _effects} = RouteState.new("remove") |> RouteState.navigate("99")
    {state, _effects} = RouteState.put_catalog(state, first)
    {state, _kind} = RouteState.put_selected(state, selected)
    assert length(RouteState.selected_snapshot(state).data.members) == 2
    File.rm!(path)
    # Point discovery at an empty list rather than a missing explicit manifest.
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [])
    on_exit(fn -> Application.delete_env(:aiur, :build_order_planning_packs) end)
    catalog = DataSource.catalog(graph_projection: Projection)
    {:ok, next} = DataSource.selected(root.identity, graph_projection: Projection)
    {state, _effects} = RouteState.put_catalog(state, catalog)
    {state, :generation} = RouteState.put_selected(state, next)
    assert [entry] = RouteState.catalog_snapshot(state).data.entries
    assert entry.title == "Live root"
    assert length(RouteState.selected_snapshot(state).data.members) == 1
  end

  test "distinct packs sharing a live root remain ambiguous", %{path: path, pack: pack, catalog: catalog} do
    repository = Aiur.GitHub.Config.repo()
    [owner, repo] = String.split(repository, "/")
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_99", "number" => 99}, {owner, repo}, {owner, repo})
    other = path <> ".second"
    File.write!(path, Jason.encode!(Map.put(pack, "repository", repository)))
    File.write!(other, Jason.encode!(pack |> Map.put("repository", repository) |> Map.put("build_order_id", "second") |> Map.put("title", "Second program")))
    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [path, other])
    on_exit(fn -> Application.delete_env(:aiur, :build_order_planning_packs) end)
    [root] = catalog.data.entries
    live = %{catalog | repository: {owner, repo}, data: %{catalog.data | entries: [%{root | identity: identity}]}}
    merged = PackOverlay.catalog(live)
    assert Enum.map(merged.data.entries, & &1.title) |> Enum.sort() == ["Full program", "Second program"]
    {state, _effects} = RouteState.new("collision") |> RouteState.navigate("99")
    {state, []} = RouteState.put_catalog(state, merged)
    assert RouteState.status(state) == :invalid_catalog
  end

  test "catalog truncation evidence survives pack overlay without counting drafts as GitHub issues", %{catalog: catalog} do
    [root] = catalog.data.entries
    root = %{root | member_count: 501, github_member_count: 501, member_read_count: 100}
    snapshot = PackOverlay.catalog(%{catalog | data: %{catalog.data | entries: [root]}})
    [merged] = snapshot.data.entries
    assert merged.member_count == 2
    assert AiurWeb.BuildOrder.Truncation.notice(merged) =~ "100 of 501"
  end

  defp render_graph(snapshot, model, collapsed \\ []) do
    render_component(&BuildOrderGraph.build_order_graph/1,
      id: "program",
      root_id: "99",
      provider_generation: 1,
      dom_generation: 1,
      model: model,
      pack_metadata: snapshot.data.pack_metadata,
      collapsed_epics: collapsed
    )
  end

  defp ticket(id, number), do: %{"id" => id, "title" => "Draft #{id}", "ticket" => number, "doc" => "tickets/#{id}.md", "phase" => 0, "lane" => "core", "complexity" => 3, "depends_on" => []}
  defp health, do: ProviderHealth.new(1, :healthy, true, observed_at: DateTime.utc_now())
  defp url(number), do: "https://github.com/acme/widgets/issues/#{number}"

  defp identity(number) do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_#{number}", "number" => number}, {"acme", "widgets"}, {"acme", "widgets"})
    identity
  end
end
