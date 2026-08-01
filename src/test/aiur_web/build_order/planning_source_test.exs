defmodule AiurWeb.BuildOrder.PlanningSourceTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.{RepoBase, TrackerIdentity}
  alias Aiur.GitHub.Config
  alias AiurWeb.BuildOrder.PlanningSource
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  @pack """
  {
    "build_order_id": "acme/widgets:demo",
    "title": "Demo Plan",
    "repository": "acme/widgets",
    "tickets": [
      {"id": "T-1", "title": "Foundation", "lane": "core", "phase": 1, "complexity": 3, "depends_on": [],
       "ticket": null, "doc": "tickets/T-1.md"},
      {"id": "T-2", "title": "Build on it", "lane": "web", "phase": 2, "complexity": 2, "depends_on": ["T-1"],
       "ticket": null, "doc": "tickets/T-2.md"}
    ]
  }
  """

  @canonical_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 2,
       "complexity": 3, "ticket": 4101, "doc": "tickets/AS-101.md", "depends_on": []},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 3,
       "complexity": 2, "ticket": 4102, "doc": "tickets/AS-102.md", "depends_on": ["AS-101"]}
    ]
  }
  """

  @mixed_pack """
  {
    "build_order_id": "acme/widgets:analytics-streamdeck",
    "title": "Analytics Stream Deck",
    "icon": "bolt",
    "repository": "acme/widgets",
    "root_number": 9900,
    "tickets": [
      {"id": "AS-101", "title": "Wire stream", "lane": "runtime", "phase": 1,
       "complexity": 3, "depends_on": [], "ticket": 4101, "doc": "tickets/AS-101.md"},
      {"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 2,
       "complexity": 2, "depends_on": ["AS-101"], "ticket": null, "doc": "tickets/AS-102.md", "icon": "sparkles"}
    ]
  }
  """

  setup do
    path = Path.join(System.tmp_dir!(), "planning-source-test-#{System.unique_integer([:positive])}.json")
    File.write!(path, @pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn -> %{generation: 0, members: []} end)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
      File.rm(path)
    end)

    :ok
  end

  test "catalog exposes one selectable planning root" do
    snapshot = PlanningSource.catalog()

    assert %Snapshot{scope: :catalog, authority_epoch: epoch, generation: gen} = snapshot
    assert is_integer(epoch) and epoch > 0
    assert is_integer(gen) and gen > 0

    assert %Catalog{entries: [root]} = snapshot.data
    assert root.title == "Demo Plan"
    assert TrackerIdentity.joinable?(root.identity)
  end

  test "selected root builds a valid, planning-flagged view model" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)

    assert %Snapshot{scope: {:selected, _identity}} = snapshot
    assert %SelectedRoot{planning?: true} = snapshot.data

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    assert model.status == :ready
    assert model.planning?
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert Map.keys(model.summary.lanes) |> Enum.sort() == ["core", "web"]

    # Planning tickets retain their canonical local draft path.
    node = Enum.find(model.nodes, &(&1.card.identifier == "1"))
    assert node.document_path == "tickets/T-1.md"
  end

  test "planning tickets render as planned with neutral dependency edges" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    grid = BuildOrderGridModel.build(model, nil)

    assert grid.planning?
    assert Enum.all?(grid.cards, &(&1.state == :planned))
    assert Enum.all?(grid.cards, &(&1.status_word == "planned"))
    assert Enum.all?(grid.edges, &(&1.state == "planned"))
  end

  test "missing pack yields no catalog rather than crashing" do
    Application.put_env(:aiur, :build_order_planning_pack, "/does/not/exist.json")
    assert PlanningSource.catalog() == nil
  end

  test "hydrates canonical ticket fields from membership without tracker reads" do
    path = Path.join(System.tmp_dir!(), "planning-source-canonical-#{System.unique_integer([:positive])}.json")
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.identity.identifier == "9900"
    assert root.identity.provider_id == "BO_ROOT"
    assert is_nil(root.progress)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 7, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :completed}]}
    end)

    [hydrated_root] = PlanningSource.catalog().data.entries
    assert hydrated_root.progress == 50

    {:ok, hydrated} = PlanningSource.demand(root.identity)
    assert hydrated.generation == 8
    refute hydrated.data.planning?

    [closed, open] = hydrated.data.members
    assert closed.identity.identifier == "4101"
    assert closed.identity.provider_id == "I_live_4101"
    assert closed.lifecycle.state == :closed
    assert open.identity.identifier == "4102"
    assert open.lifecycle.state == :open

    model = BuildOrderPresenter.present(hydrated, :unavailable, :unavailable)
    assert Map.keys(model.summary.lanes) |> Enum.sort() == ["dashboard-ui", "runtime"]
    assert Enum.map(model.phase_groups, & &1.key) == [2, 3]

    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_pct == 60
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).pct == 100
    assert Enum.find(grid.waves, &(&1.phase == 2)).pct == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).pct == 0
  end

  test "does not count cancelled members as completed progress" do
    path = Path.join(System.tmp_dir!(), "planning-source-cancelled-#{System.unique_integer([:positive])}.json")
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 8, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :cancelled}]}
    end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 0

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [cancelled, _open] = snapshot.data.members
    assert cancelled.lifecycle.state == :closed
    assert cancelled.lifecycle.state_reason == :not_planned

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    assert BuildOrderGridModel.build(model, nil).overall_pct == 0
  end

  test "uses status.json for canonical members when no live membership exists" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members
    assert created.lifecycle.state == :closed
    assert draft.lifecycle.state == :open
  end

  test "renders created members live and uncreated members as planned from one canonical pack" do
    directory = Path.join(System.tmp_dir!(), "planning-source-mixed-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")
    document = Path.join([directory, "tickets", "AS-102.md"])

    File.mkdir_p!(Path.dirname(document))
    File.write!(document, "# Render deck\n\nDraft ticket body.")
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      {:ok, colliding_draft_identity} =
        TrackerIdentity.from_github(
          %{"number" => 102, "node_id" => "I_live_102"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :fresh},
        members: [
          %{identity: identity, lifecycle: :completed},
          %{identity: colliding_draft_identity, lifecycle: :completed}
        ]
      }
    end)

    [root] = PlanningSource.catalog().data.entries
    assert root.icon == "bolt"
    assert root.progress == 50

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members
    refute created.draft?
    assert created.lifecycle.state == :closed
    assert draft.draft?
    assert draft.lifecycle.state == :open
    assert draft.document_path == "tickets/AS-102.md"
    assert draft.draft_body == "# Render deck\n\nDraft ticket body."

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model, nil)
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert %{state: :planned, icon: "sparkles"} = Enum.find(grid.cards, &(&1.id == "102"))
    assert grid.overall_pct == 60
    assert Enum.find(model.nodes, & &1.card.planned?).draft_body == "# Render deck\n\nDraft ticket body."
  end

  test "marks membership recovery failures unavailable instead of trusted open state" do
    [root] = PlanningSource.catalog().data.entries

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 9, health: {:unavailable, :recovery_unavailable}, members: []}
    end)

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    assert snapshot.health.state == :unavailable
    refute snapshot.health.complete?

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    assert model.status == :provider_unavailable
  end

  test "discovers canonical packs from the runtime build-order directory" do
    directory = Path.join(System.tmp_dir!(), "planning-source-discovery-#{System.unique_integer([:positive])}")
    previous_root = Application.get_env(:aiur, :repo_base_root)
    previous_dirs = System.get_env("AIUR_BUILD_ORDER_DIRS")
    repository = Config.repo()

    Application.put_env(:aiur, :repo_base_root, directory)
    path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "analytics-streamdeck", "build-order.json"])
    second_path = Path.join([RepoBase.builds_path("https://github.com/#{repository}.git"), "second-build", "build-order.json"])

    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(second_path))
    File.write!(path, @canonical_pack)

    File.write!(
      second_path,
      @canonical_pack
      |> String.replace("acme/widgets:analytics-streamdeck", "acme/widgets:second-build")
      |> String.replace("Analytics Stream Deck", "Second runtime build")
      |> String.replace("\"root_number\": 9900", "\"root_number\": 9901")
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.delete_env(:aiur, :build_order_planning_packs)
    System.delete_env("AIUR_BUILD_ORDER_DIRS")

    on_exit(fn ->
      if previous_root, do: Application.put_env(:aiur, :repo_base_root, previous_root), else: Application.delete_env(:aiur, :repo_base_root)
      if previous_dirs, do: System.put_env("AIUR_BUILD_ORDER_DIRS", previous_dirs), else: System.delete_env("AIUR_BUILD_ORDER_DIRS")
      File.rm_rf(directory)
    end)

    roots = PlanningSource.catalog().data.entries
    root = Enum.find(roots, &(&1.identity.identifier == "9900"))
    assert root.identity.provider_id == "BO_ROOT"
    assert Enum.map(roots, & &1.identity.identifier) |> Enum.sort() == ["9900", "9901"]
  end

  test "assigns distinct deterministic catalog icons when packs omit one" do
    first = Path.join(System.tmp_dir!(), "planning-source-first-#{System.unique_integer([:positive])}.json")
    second = Path.join(System.tmp_dir!(), "planning-source-second-#{System.unique_integer([:positive])}.json")

    File.write!(first, @pack)

    File.write!(
      second,
      @pack
      |> String.replace("acme/widgets:demo", "acme/widgets:second-demo")
      |> String.replace("Demo Plan", "Second Demo Plan")
      |> String.replace("\"T-1\"", "\"S-1\"")
      |> String.replace("\"T-2\"", "\"S-2\"")
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [first, second])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm(first)
      File.rm(second)
    end)

    icons = PlanningSource.catalog().data.entries |> Enum.map(& &1.icon)
    assert Enum.uniq(icons) |> length() == 2
  end
end
