defmodule AiurWeb.BuildOrder.PlanningSourceTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrder.{Catalog, ProviderHealth, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.GitHub.Config
  alias Aiur.{RepoBase, TrackerIdentity}
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

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(1, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_pack)
      Application.delete_env(:aiur, :build_order_planning_membership_snapshot)
      Application.delete_env(:aiur, :build_order_pack_status_health_snapshot)
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
    catalog = PlanningSource.catalog()
    [root] = catalog.data.entries
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
    catalog = PlanningSource.catalog()
    [root] = catalog.data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    grid = BuildOrderGridModel.build(model)

    assert grid.planning?
    assert Enum.all?(grid.cards, &(&1.state == :planned))
    assert Enum.all?(grid.cards, &(&1.status_word == "planned"))
    assert Enum.all?(grid.edges, &(&1.state == "planned"))
  end

  test "defaults members without provenance to the approved planned baseline" do
    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)

    assert Enum.all?(model.nodes, &(&1.plan.provenance == :planned))
    assert Enum.all?(model.nodes, &is_nil(&1.plan.added_at))
  end

  test "keeps a discovered member in its lane and exposes baseline drift" do
    path = Path.join(System.tmp_dir!(), "planning-source-discovered-#{System.unique_integer([:positive])}.json")

    pack =
      String.replace(
        @canonical_pack,
        ~s({"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 3,),
        ~s({"id": "AS-102", "title": "Render deck", "lane": "dashboard-ui", "phase": 3, "provenance": "discovered", "added_at": "2026-08-01T12:00:00Z",)
      )

    File.write!(path, pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 1, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :completed}]}
    end)

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model)

    discovered = Enum.find(model.nodes, &(&1.plan.provenance == :discovered))
    assert discovered.plan.added_at == ~U[2026-08-01 12:00:00Z]
    assert %{lane: "dashboard-ui", phase: 3, discovered?: true} = Enum.find(grid.cards, & &1.discovered?)
    assert %{baseline_total: 1, discovered_total: 1, total: 2} = grid.totals
    assert grid.overall_pct == 60
    assert %{source: "4101", target: "4102", state: "cleared"} in grid.edges
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

    catalog = PlanningSource.catalog()
    [root] = catalog.data.entries
    assert root.identity.identifier == "9900"
    assert root.identity.provider_id == "BO_acme/widgets:analytics-streamdeck"
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
    assert is_nil(hydrated_root.progress)

    {:ok, hydrated} = PlanningSource.demand(root.identity)
    assert hydrated.generation > 8
    refute hydrated.data.planning?

    [closed, unknown] = hydrated.data.members
    assert closed.identity.identifier == "4101"
    assert closed.identity.provider_id == "I_live_4101"
    assert closed.lifecycle.state == :closed
    assert unknown.identity.identifier == "4102"
    assert unknown.lifecycle.state == :unknown

    model = BuildOrderPresenter.present(hydrated, :unavailable, :unavailable)
    assert Map.keys(model.summary.lanes) |> Enum.sort() == ["dashboard-ui", "runtime"]
    assert Enum.map(model.phase_groups, & &1.key) == [2, 3]

    grid = BuildOrderGridModel.build(model)
    assert grid.overall_pct == nil
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).pct == 100
    assert Enum.find(grid.waves, &(&1.phase == 2)).pct == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).pct == nil
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
    assert is_nil(root.progress)

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [cancelled, _open] = snapshot.data.members
    assert cancelled.lifecycle.state == :closed
    assert cancelled.lifecycle.state_reason == :not_planned

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model)
    assert grid.overall_pct == nil
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).pct == 0
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

  test "tracker completion outranks active current-run membership" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-completed-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [completed, _draft] = snapshot.data.members
    assert completed.lifecycle.state == :closed
    assert completed.lifecycle.state_reason == :completed

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    assert card.state == :merged
    assert card.progress == 100
    assert card.status_word == "merged"
  end

  test "tracker reopen outranks terminal current-run membership" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-open-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"state":"completed","members":{"4101":"open"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :completed)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 0

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [reopened, _draft] = snapshot.data.members
    assert reopened.lifecycle.state == :open
    assert reopened.lifecycle.state_reason == :none

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    refute card.state == :merged
    refute card.status_word == "merged"
  end

  test "marks a retained status projection stale when PackStatus is unavailable" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-stale-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :stale
    refute snapshot.health.complete?
    assert snapshot.health.failure == :pack_status_unavailable
  end

  test "marks missing status unavailable when PackStatus has no projection" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-unavailable-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :unavailable
    refute snapshot.health.complete?
    assert snapshot.health.failure == :pack_status_unavailable

    [root] = snapshot.data.entries
    assert root.progress == nil
    {:ok, selected} = PlanningSource.demand(root.identity)
    [promoted, draft] = selected.data.members

    assert promoted.lifecycle.state == :unknown
    assert promoted.lifecycle.state_reason == :unknown
    assert draft.lifecycle.state == :open

    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)
    assert grid.overall_pct == nil
    refute Enum.find(grid.cards, &(&1.id == "4101")).has_progress
  end

  test "downgrades healthy PackStatus when a promoted member lacks a projection" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-incomplete-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @canonical_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4102, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :stale
    refute snapshot.health.complete?
    assert snapshot.health.failure == :pack_status_incomplete

    [root] = snapshot.data.entries
    assert root.progress == nil
    {:ok, selected} = PlanningSource.demand(root.identity)
    [completed, missing] = selected.data.members

    assert completed.lifecycle.state == :closed
    assert missing.lifecycle.state == :unknown
    assert missing.lifecycle.state_reason == :unknown

    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)
    assert grid.overall_pct == nil
    assert Enum.find(grid.waves, &(&1.phase == 2)).pct == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).pct == nil
  end

  test "preserves PackStatus budget exhaustion through an incomplete projection" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-budget-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @canonical_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(2, :stale, false, failure: :planning_call_budget_exhausted)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :planning_call_budget_exhausted
    refute snapshot.health.complete?
  end

  test "ignores a malformed status members shape" do
    directory = Path.join(System.tmp_dir!(), "planning-source-status-malformed-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":[]}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :unavailable
    assert snapshot.health.failure == :pack_status_incomplete
  end

  test "membership recovery does not regress the PackStatus-backed generation" do
    path = Path.join(System.tmp_dir!(), "planning-source-generation-#{System.unique_integer([:positive])}.json")
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(5, :healthy, true, observed_at: ~U[2026-08-02 12:00:00Z])
    end)

    on_exit(fn -> File.rm(path) end)

    initial_generation = PlanningSource.catalog().generation

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 1, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: :completed}]}
    end)

    assert PlanningSource.catalog().generation > initial_generation
  end

  test "renders created members live and uncreated members as planned from one canonical pack" do
    directory = Path.join(System.tmp_dir!(), "planning-source-mixed-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")
    document = Path.join([directory, "tickets", "AS-102.md"])

    File.mkdir_p!(Path.dirname(document))
    File.write!(document, "# Render deck\n\nDraft ticket body.")
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
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
    assert is_nil(created.draft_body)
    assert draft.draft?
    assert draft.lifecycle.state == :open
    assert draft.identity.provider_id == "PLAN_AS-102"
    assert draft.document_path == "tickets/AS-102.md"
    assert draft.draft_body == "# Render deck\n\nDraft ticket body."

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model)
    assert Enum.find(grid.cards, &(&1.id == "4101")).state == :merged
    assert %{state: :planned, icon: "sparkles"} = Enum.find(grid.cards, &(&1.id == "102"))
    assert grid.overall_pct == 60
    assert Enum.find(model.nodes, & &1.card.planned?).draft_body == "# Render deck\n\nDraft ticket body."
  end

  test "rejects a draft document outside its pack ticket directory" do
    directory = Path.join(System.tmp_dir!(), "planning-source-document-boundary-#{System.unique_integer([:positive])}")
    path = Path.join(directory, "build-order.json")
    outside_document = directory <> ".md"

    File.mkdir_p!(directory)
    File.write!(outside_document, "must not render")
    File.write!(path, String.replace(@mixed_pack, "tickets/AS-102.md", "../#{Path.basename(outside_document)}"))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn ->
      File.rm_rf(directory)
      File.rm(outside_document)
    end)

    assert PlanningSource.catalog() == nil
  end

  test "uses live labels for created tickets and pack labels for drafts" do
    path = Path.join(System.tmp_dir!(), "planning-source-live-labels-#{System.unique_integer([:positive])}.json")
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => 4101, "node_id" => "I_live_4101"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :fresh},
        members: [%{identity: identity, lifecycle: :queued}],
        labels_by_identity: %{TrackerIdentity.github_key(identity) => ["agent:rework"]}
      }
    end)

    [root] = PlanningSource.catalog().data.entries
    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members

    assert created.labels == ["agent:rework"]
    assert draft.labels == ["build-lane:dashboard-ui", "phase:2", "complexity:2"]
  end

  test "rejects members without canonical ticket or document fields" do
    path = Path.join(System.tmp_dir!(), "planning-source-invalid-schema-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    File.write!(path, String.replace(@pack, "\"ticket\": null", "\"ticket\": -1"))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    assert PlanningSource.catalog() == nil

    File.write!(path, String.replace(@pack, "\"doc\": \"tickets/T-1.md\"", "\"doc\": \"plan.md\""))
    assert PlanningSource.catalog() == nil
  end

  test "rejects discovered members without a valid provenance timestamp" do
    path = Path.join(System.tmp_dir!(), "planning-source-invalid-provenance-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    for replacement <- [
          ~s("ticket": null, "provenance": "discovered", "doc": "tickets/T-1.md"),
          ~s("ticket": null, "provenance": "discovered", "added_at": "not-a-date", "doc": "tickets/T-1.md"),
          ~s("ticket": null, "provenance": "unknown", "doc": "tickets/T-1.md")
        ] do
      File.write!(path, String.replace(@pack, ~s("ticket": null, "doc": "tickets/T-1.md"), replacement, global: false))
      Application.put_env(:aiur, :build_order_planning_pack, path)

      assert PlanningSource.catalog() == nil
    end
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
      |> String.replace("4101", "5101")
      |> String.replace("4102", "5102")
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
    assert root.identity.provider_id == "BO_acme/widgets:analytics-streamdeck"
    assert Enum.map(roots, & &1.identity.identifier) |> Enum.sort() == ["9900", "9901"]

    [first, second] = roots
    {:ok, first_snapshot} = PlanningSource.demand(first.identity)
    {:ok, second_snapshot} = PlanningSource.demand(second.identity)

    first_tickets = MapSet.new(first_snapshot.data.members, & &1.identity.identifier)
    second_tickets = MapSet.new(second_snapshot.data.members, & &1.identity.identifier)
    assert MapSet.disjoint?(first_tickets, second_tickets)
  end

  test "rejects every pack that claims the same materialized ticket regardless of repository casing" do
    first = Path.join(System.tmp_dir!(), "planning-source-conflict-first-#{System.unique_integer([:positive])}.json")
    second = Path.join(System.tmp_dir!(), "planning-source-conflict-second-#{System.unique_integer([:positive])}.json")
    File.write!(first, @canonical_pack)

    File.write!(
      second,
      @canonical_pack
      |> String.replace("analytics-streamdeck", "duplicate-build")
      |> String.replace("acme/widgets", "AcMe/WiDgEtS")
    )

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [first, second])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm(first)
      File.rm(second)
    end)

    assert PlanningSource.catalog() == nil
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

    root_ids = PlanningSource.catalog().data.entries |> Enum.map(& &1.identity.identifier)
    assert Enum.uniq(root_ids) |> length() == 2
  end

  test "pins active build orders before completed entries sorted by completion date" do
    directory = Path.join(System.tmp_dir!(), "planning-source-catalog-sort-#{System.unique_integer([:positive])}")
    active = Path.join([directory, "active", "build-order.json"])
    recent = Path.join([directory, "recent", "build-order.json"])
    older = Path.join([directory, "older", "build-order.json"])

    for path <- [active, recent, older], do: File.mkdir_p!(Path.dirname(path))

    File.write!(active, @pack)
    File.write!(recent, @pack |> String.replace("Demo Plan", "Recent completed") |> String.replace(":demo", ":recent"))
    File.write!(older, @pack |> String.replace("Demo Plan", "Older completed") |> String.replace(":demo", ":older"))
    File.write!(Path.join(Path.dirname(recent), "status.json"), ~s({"state":"completed","completed_at":"2026-08-01T12:00:00Z"}))
    File.write!(Path.join(Path.dirname(older), "status.json"), ~s({"state":"completed","completed_at":"2026-07-31T12:00:00Z"}))

    Application.delete_env(:aiur, :build_order_planning_pack)
    Application.put_env(:aiur, :build_order_planning_packs, [older, active, recent])

    on_exit(fn ->
      Application.delete_env(:aiur, :build_order_planning_packs)
      File.rm_rf(directory)
    end)

    entries = PlanningSource.catalog().data.entries
    assert Enum.map(entries, & &1.title) == ["Demo Plan", "Recent completed", "Older completed"]
    assert Enum.map(entries, & &1.completed?) == [false, true, true]
  end

  defp put_membership(number, lifecycle) do
    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      {:ok, identity} =
        TrackerIdentity.from_github(
          %{"number" => number, "node_id" => "I_live_#{number}"},
          {"acme", "widgets"},
          {"acme", "widgets"}
        )

      %{generation: 9, health: :healthy, freshness: %{status: :fresh}, members: [%{identity: identity, lifecycle: lifecycle}]}
    end)
  end
end
