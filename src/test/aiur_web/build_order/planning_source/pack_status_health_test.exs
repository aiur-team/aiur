defmodule AiurWeb.BuildOrder.PlanningSource.PackStatusHealthTest do
  use AiurWeb.BuildOrder.PlanningSourceCase

  test "uses status.json for canonical members when no live membership exists" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [created, draft] = snapshot.data.members
    assert created.lifecycle.state == :closed
    assert draft.lifecycle.state == :open
  end

  test "tracker completion outranks active current-run membership" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-completed")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 50
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [completed, _draft] = snapshot.data.members
    assert completed.lifecycle.state == :closed
    assert completed.lifecycle.state_reason == :completed

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    assert card.state == :merged
    assert card.completion.progress == 100
    assert card.status_word == "merged"
  end

  test "tracker reopen outranks terminal current-run membership" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-open")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"state":"completed","members":{"4101":"open"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4101, :completed)

    on_exit(fn -> File.rm_rf(directory) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress == 0
    assert root.progress_resolution == :resolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [reopened, _draft] = snapshot.data.members
    assert reopened.lifecycle.state == :open
    assert reopened.lifecycle.state_reason == :none

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    card = model |> BuildOrderGridModel.build(nil) |> Map.fetch!(:cards) |> Enum.find(&(&1.id == "4101"))
    refute card.state == :merged
    refute card.status_word == "merged"
  end

  test "keeps the plan readable and marks a retained status projection stale" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-stale")
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
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_unavailable
  end

  test "keeps the plan readable while missing ticket status remains unavailable" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-unavailable")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_pack_status_health_snapshot, fn ->
      ProviderHealth.new(:unknown, :unavailable, false, failure: :pack_status_unavailable)
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :unavailable
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_unavailable

    [root] = snapshot.data.entries
    # The draft resolves and the promoted member does not: a partial pack keeps
    # the percentage it can defend and publishes its coverage alongside it.
    assert root.progress == 0
    assert root.progress_resolution == :partial
    assert root.progress_resolved_count == 1
    assert root.member_count == 2
    {:ok, selected} = PlanningSource.demand(root.identity)
    assert selected.health.state == :healthy
    assert selected.status_health.state == :unavailable
    [promoted, draft] = selected.data.members

    assert promoted.lifecycle.state == :unknown
    assert promoted.lifecycle.state_reason == :unknown
    assert draft.lifecycle.state == :open

    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert model.status == :ready
    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 0, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.cards, &(&1.id == "4101")).completion.progress_resolution == :unresolved
  end

  test "downgrades healthy PackStatus when a promoted member lacks a projection" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-incomplete")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @canonical_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":{"4101":"completed"}}))
    Application.put_env(:aiur, :build_order_planning_pack, path)
    put_membership(4102, :running)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    refute snapshot.status_health.complete?
    assert snapshot.status_health.failure == :pack_status_incomplete

    [root] = snapshot.data.entries
    # One of two resolved and complete: 50% is the lower bound over both members.
    assert root.progress == 50
    assert root.progress_resolution == :partial
    assert root.progress_resolved_count == 1
    assert root.member_count == 2
    {:ok, selected} = PlanningSource.demand(root.identity)
    [completed, active] = selected.data.members

    assert completed.lifecycle.state == :closed
    assert active.lifecycle.state == :open
    assert active.lifecycle.state_reason == :none

    grid = selected |> BuildOrderPresenter.present(:unavailable, :unavailable) |> BuildOrderGridModel.build(nil)
    # The grid agrees with the catalog root: the open member with no activity reading is unresolved, not a resolved 0%.
    assert grid.overall_completion == %{progress: 60, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.waves, &(&1.phase == 2)).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).completion.progress_resolution == :unresolved
  end

  test "preserves PackStatus budget exhaustion through an incomplete projection" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-budget")
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
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :stale
    assert snapshot.status_health.failure == :planning_call_budget_exhausted
    refute snapshot.status_health.complete?
  end

  test "ignores a malformed status members shape" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-status-malformed")
    path = Path.join(directory, "build-order.json")

    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    File.write!(Path.join(directory, "status.json"), ~s({"members":[]}))
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm_rf(directory) end)

    snapshot = PlanningSource.catalog()
    assert snapshot.health.state == :healthy
    assert snapshot.status_health.state == :unavailable
    assert snapshot.status_health.failure == :pack_status_incomplete
  end

  test "membership recovery does not regress the PackStatus-backed generation" do
    path = Aiur.TestSupport.tmp_root!("planning-source-generation") <> ".json"
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
end
