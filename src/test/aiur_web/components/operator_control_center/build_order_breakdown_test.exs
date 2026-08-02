defmodule AiurWeb.OperatorControlCenter.BuildOrderBreakdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Aiur.BuildOrder.{Dependency, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.OperatorControlCenter.BuildOrderBreakdown

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  describe "projection/1" do
    test "folds counts, points, weights, and KPI facts over a multi-member plan" do
      model = model([m(1, phase: 1, lane: "plan-graph", cx: 3), m(2, phase: 1, lane: "runtime", cx: 2, blockers: [1]), m(3, phase: 2, lane: "runtime", cx: 4, blockers: [2])])

      projection = BuildOrderBreakdown.projection(model)

      assert projection.status == :ready
      assert projection.kpis == %{members: 3, points: 9, ready_at_start: 1, longest_chain: 3}

      phase_one = row(projection.phases, 1)
      phase_two = row(projection.phases, 2)
      assert phase_one.label == "Wave 1" and phase_one.count == 2 and phase_one.points == 5 and phase_one.weight == 1.0
      assert phase_two.count == 1 and phase_two.points == 4 and phase_two.weight == 4 / 5

      plan_graph = row(projection.epics, "plan-graph")
      runtime = row(projection.epics, "runtime")
      assert plan_graph.label == "Plan graph" and plan_graph.count == 1 and plan_graph.points == 3
      assert runtime.label == "Runtime" and runtime.count == 2 and runtime.points == 6
      assert runtime.weight == 1.0 and plan_graph.weight == 0.5

      assert projection.warnings == []
    end

    test "handles a single-member plan" do
      projection = BuildOrderBreakdown.projection(model([m(1, phase: 3, lane: "runtime", cx: 5)]))

      assert projection.kpis == %{members: 1, points: 5, ready_at_start: 1, longest_chain: 1}
      assert [%{count: 1, points: 5, weight: 1.0}] = projection.phases
    end

    test "reports an empty plan without zeros-as-healthy tables" do
      projection = BuildOrderBreakdown.projection(model([]))

      assert projection.status == :empty
      assert projection.phases == [] and projection.epics == []
      assert projection.kpis.members == 0 and projection.kpis.points == 0
    end

    test "buckets members with missing complexity and excludes them from point totals" do
      model = model([m(1, phase: 1, lane: "runtime", cx: 3), bare(2, ["phase:1", "build-lane:runtime"])])

      projection = BuildOrderBreakdown.projection(model)

      runtime = row(projection.epics, "runtime")
      assert runtime.count == 2, "the member is counted, never silently dropped"
      assert runtime.points == 3, "only the usable complexity is summed"

      assert [%{reason: "missing or invalid complexity"} = warning] = projection.warnings
      assert warning.card.identifier == "2"
    end

    test "buckets duplicate-identity members and excludes them from totals" do
      activity = activity_snapshot([activity(identity(2)), activity(identity(2))])
      model = model([m(1, phase: 1, lane: "runtime", cx: 3), m(2, phase: 1, lane: "runtime", cx: 4)], activity: activity)

      projection = BuildOrderBreakdown.projection(model)

      assert [%{reason: "duplicate identity", card: %{identifier: "2"}}] = projection.warnings
      assert row(projection.epics, "runtime").points == 3
    end

    test "carries the named degraded status instead of an empty table" do
      stale = ProviderHealth.new(9, :stale, false, observed_at: @now, last_success_at: @now)
      projection = BuildOrderBreakdown.projection(model([m(1)], health: stale))

      assert projection.status == :provider_stale
    end

    test "separates the approved baseline from discovered members without excluding their points" do
      projection = BuildOrderBreakdown.projection(model([m(1, cx: 3), m(2, cx: 4, provenance: :discovered, added_at: @now)]))

      assert projection.baseline_total == 1
      assert projection.discovered_total == 1
      assert projection.kpis.points == 7
    end
  end

  describe "build_order_breakdown/1" do
    test "renders the epics list with coloured icons, members, and a progress bar" do
      html = render_breakdown(model([m(1, phase: 1, lane: "plan-graph", cx: 3), m(2, phase: 2, lane: "runtime", cx: 4, blockers: [1])]))

      assert html =~ "bo-breakdown-list-title"
      assert html =~ ">Epics<"
      assert html =~ ~s(class="bo-breakdown-row-name">)
      assert html =~ ~s(class="bo-breakdown-row-members">)
      # Each epic row carries a coloured epic icon.
      assert html =~ "bo-breakdown-row-ic"
      # A full-width progress bar sits along the bottom of each epic row.
      assert html =~ ~s(<span class="bo-breakdown-row-bar" aria-hidden="true">)
      # Plan-distribution stats, the phase block, and the rollout note are gone.
      refute html =~ "Plan distribution"
      refute html =~ "Ready at start"
      refute html =~ ~s(id="bo-phase-breakdown")
    end

    test "renders the named stale state when degraded" do
      stale = ProviderHealth.new(9, :stale, false, observed_at: @now, last_success_at: @now)
      html = render_breakdown(model([m(1, phase: 1, lane: "runtime", cx: 3)], health: stale))

      assert html =~ "Plan distribution is stale"
      refute html =~ "bo-breakdown-table"
    end

    test "surfaces discovered-member drift" do
      html = render_breakdown(model([m(1, cx: 3), m(2, cx: 4, provenance: :discovered, added_at: @now)]))

      assert html =~ "1 baseline members; 1 added after start."
    end
  end

  defp render_breakdown(model), do: render_component(&BuildOrderBreakdown.build_order_breakdown/1, model: model)

  defp row(rows, key), do: Enum.find(rows, &(&1.key == key))

  defp model(members, opts \\ []) do
    activity = Keyword.get(opts, :activity, activity_snapshot([]))
    BuildOrderPresenter.present(snapshot(members, opts), status_snapshot(), activity)
  end

  defp snapshot(members, opts) do
    root_identity = identity(100)
    health = Keyword.get(opts, :health, ProviderHealth.new(7, :healthy, true, observed_at: @now))
    selected = SelectedRoot.new(root(root_identity), members, health)

    %Snapshot{
      scope: {:selected, root_identity},
      repository: @repository,
      generation: 7,
      data: selected,
      health: health
    }
  end

  defp root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order",
      url: issue_url(identity.identifier),
      state: :open,
      state_reason: nil,
      labels: ["build-order"],
      updated_at: @now
    })
  end

  defp m(number, opts \\ []) do
    labels = ["complexity:#{Keyword.get(opts, :cx, 3)}", "phase:#{Keyword.get(opts, :phase, 1)}", "build-lane:#{Keyword.get(opts, :lane, "plan-graph")}"]
    dependencies = Enum.map(Keyword.get(opts, :blockers, []), &Dependency.new(identity(number), identity(&1), issue_url(&1), :blocked_by))

    Member.new(%{
      identity: identity(number),
      title: "Ticket #{number}",
      url: issue_url(number),
      state: :open,
      labels: labels,
      updated_at: @now,
      dependencies: dependencies,
      provenance: Keyword.get(opts, :provenance),
      added_at: Keyword.get(opts, :added_at)
    })
  end

  defp bare(number, labels) do
    Member.new(%{identity: identity(number), title: "Ticket #{number}", url: issue_url(number), state: :open, labels: labels, updated_at: @now})
  end

  defp status_snapshot, do: %{running: [], retrying: [], idle: []}
  defp activity_snapshot(entries), do: %{generation: 12, entries: entries, diagnostics: %{}}

  defp activity(identity) do
    %{
      identity: identity,
      status: :fresh,
      active_stage: :work,
      stage: %{status: :known, value: :work, freshness: :fresh, observed_at: @now, event_id: 2},
      progress: %{status: :known, percent: 10, source: :checkin, freshness: :fresh, occurred_at: @now, observed_at: @now, event_id: 3},
      latest_evidence: %{status: :unknown},
      provenance: %{},
      observed_at: @now,
      retention: :current
    }
  end

  defp identity(number) do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "ISSUE-#{number}",
      identifier: to_string(number),
      reason: nil
    }
  end

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
