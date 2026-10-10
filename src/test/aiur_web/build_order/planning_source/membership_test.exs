defmodule AiurWeb.BuildOrder.PlanningSource.MembershipTest do
  use AiurWeb.BuildOrder.PlanningSourceCase

  test "hydrates canonical ticket fields from membership without tracker reads" do
    path = Aiur.TestSupport.tmp_root!("planning-source-canonical") <> ".json"
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.identity.identifier == "9900"
    assert root.identity.provider_id == "BO_acme/widgets:analytics-streamdeck"
    assert is_nil(root.progress)
    assert root.progress_resolution == :unresolved

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
    assert hydrated_root.progress_resolution == :unresolved

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

    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 60, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 2)).completion.progress == 100
    assert Enum.find(grid.waves, &(&1.phase == 3)).completion.progress_resolution == :unresolved
  end

  test "does not count cancelled members as completed progress" do
    path = Aiur.TestSupport.tmp_root!("planning-source-cancelled") <> ".json"
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
    assert root.progress_resolution == :unresolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [cancelled, _open] = snapshot.data.members
    assert cancelled.lifecycle.state == :closed
    assert cancelled.lifecycle.state_reason == :not_planned

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    grid = BuildOrderGridModel.build(model, nil)
    assert grid.overall_completion == %{progress: 0, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
    assert Enum.find(grid.columns, &(&1.lane == "runtime")).completion.progress == 0
  end

  test "marks membership recovery failures unavailable instead of trusted open state" do
    [root] = PlanningSource.catalog().data.entries

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 9, health: {:unavailable, :recovery_unavailable}, members: []}
    end)

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    assert snapshot.health.state == :healthy
    assert snapshot.health.complete?
    assert snapshot.membership_health.state == :unavailable
    assert snapshot.membership_health.failure == :membership_unavailable

    model = BuildOrderPresenter.present(snapshot, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert Enum.all?(model.nodes, & &1.card.planned?)
  end

  test "unavailable membership cannot supply a terminal ticket state" do
    path = Aiur.TestSupport.tmp_root!("planning-source-unavailable-member") <> ".json"
    File.write!(path, @canonical_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    {:ok, live_identity} =
      TrackerIdentity.from_github(
        %{"number" => 4101, "node_id" => "I_stale_4101"},
        {"acme", "widgets"},
        {"acme", "widgets"}
      )

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{
        generation: 9,
        health: :healthy,
        freshness: %{status: :unavailable},
        members: [%{identity: live_identity, lifecycle: :completed, labels: ["agent:done"]}]
      }
    end)

    on_exit(fn -> File.rm(path) end)

    [root] = PlanningSource.catalog().data.entries
    assert root.progress_resolution == :unresolved

    {:ok, snapshot} = PlanningSource.demand(root.identity)
    [member | _] = snapshot.data.members
    assert member.lifecycle.state == :unknown
    assert member.identity.provider_id == "PLAN_AS-101"
    refute "agent:done" in member.labels
  end

  test "cold globally paused membership keeps a mixed materialized plan readable" do
    directory = Aiur.TestSupport.tmp_root!("planning-source-paused-mixed")
    path = Path.join(directory, "build-order.json")
    File.mkdir_p!(directory)
    File.write!(path, @mixed_pack)
    Application.put_env(:aiur, :build_order_planning_pack, path)

    Application.put_env(:aiur, :build_order_planning_membership_snapshot, fn ->
      %{generation: 0, health: :healthy, freshness: %{status: :unavailable}, members: []}
    end)

    on_exit(fn -> File.rm_rf(directory) end)

    catalog = PlanningSource.catalog()
    assert catalog.health.state == :healthy
    assert catalog.membership_health.state == :unavailable
    assert catalog.status_health.state == :unavailable
    assert [%{identity: identity, progress_resolution: :partial}] = catalog.data.entries

    {:ok, selected} = PlanningSource.demand(identity)
    assert selected.health.state == :healthy
    assert selected.membership_health.state == :unavailable
    assert [%{lifecycle: %{state: :unknown}}, %{draft?: true}] = selected.data.members

    model = BuildOrderPresenter.present(selected, :unavailable, :unavailable)
    assert model.status == :ready
    assert length(model.nodes) == 2
    assert length(model.edges) == 1
    assert [%{url: "https://github.com/acme/widgets/issues/4101"}] = model.edges
    refute Enum.any?(model.diagnostics, &(&1.code == :invalid_url))

    {route, []} = RouteState.new("paused-test") |> RouteState.navigate("9900")
    {route, [{:activate, ^identity}]} = RouteState.put_catalog(route, catalog)
    {route, :generation} = RouteState.put_selected(route, selected)

    html =
      render_component(&BuildOrderSelected.build_order_selected/1, %{
        route_state: route,
        model: model,
        now: ~U[2026-09-29 12:00:00Z],
        analytics_scope: %{state: :none},
        usage_scope: %{state: :none}
      })

    assert html =~ "The plan is readable, but live execution state is unresolved"
    assert html =~ "Ticket status is unavailable"
    assert html =~ "Build Order graph summary"

    assert {:ok, cli} = BuildOrdersCLI.build(source: PlanningSource, root: "9900")
    assert get_in(cli, ["sources", "planning_graph", "state"]) == "available"
    assert get_in(cli, ["sources", "membership", "state"]) == "unavailable"
    assert get_in(cli, ["sources", "ticket_status", "state"]) == "unavailable"
    assert get_in(cli, ["data", "graph", "status"]) == "ready"
  end
end
