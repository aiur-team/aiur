defmodule AiurWeb.OperatorControlCenter.BuildOrderGridModelTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Icon
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  @stale_at ~U[2026-09-16 20:00:00Z]

  describe "build/2 columns" do
    test "orders planning lanes by metadata order and appends Ad Hoc last" do
      model = model([node(:a, "A", "platform", 1), node(:b, "B", "plan-graph", 1)])
      adhoc = adhoc([adhoc_row("9", 1)])

      lanes = Enum.map(BuildOrderGridModel.build(model, adhoc).columns, & &1.lane)

      assert lanes == ["plan-graph", "platform", "adhoc"]
    end

    test "counts cards per column" do
      model = model([node(:a, "A", "plan-graph", 1), node(:b, "B", "plan-graph", 2)])

      [%{lane: "plan-graph", count: count}] = BuildOrderGridModel.build(model, nil).columns

      assert count == 2
    end
  end

  describe "build/2 progress and merged" do
    test "a merged (completed) card is forced to 100%" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_completed, progress: 10)])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.merged
      assert card.completion == %{progress: 100, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}
      assert card.status_word == "merged"
    end

    test "a closed ad hoc row is merged at 100%" do
      adhoc = adhoc([%{adhoc_row("9", 1) | lifecycle: :closed, progress: nil}])

      [card] = BuildOrderGridModel.build(model([]), adhoc).cards

      assert card.merged
      assert card.completion == %{progress: 100, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    test "an unresolvable live card carries an explicit unresolved contract" do
      model =
        model([
          node(:a, "A", "plan-graph", 1,
            status: :status_blocking,
            progress: :unknown,
            lifecycle: %{state: :unknown, state_reason: :unknown}
          )
        ])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{progress: nil, progress_resolution: :unresolved, progress_resolved_count: 0, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    test "renders a planned member alongside live members" do
      model = model([node(:live, "A", "plan-graph", 1, status: :status_completed), node(:draft, "B", "plan-graph", 1, planned?: true)])

      cards = BuildOrderGridModel.build(model, nil).cards

      assert Enum.find(cards, &(&1.id == "A")).state == :merged
      assert Enum.find(cards, &(&1.id == "B")).state == :planned
    end
  end

  describe "build/2 wave completion" do
    test "complexity-weights core completion per wave; merged counts full" do
      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 4),
          node(:b, "B", "plan-graph", 1, status: :status_working, complexity: 1, progress: 0)
        ])

      [wave] = BuildOrderGridModel.build(model, nil).waves

      # (4*1.0 + 1*0.0) / (4 + 1) = 80%
      assert wave.completion == %{progress: 80, progress_resolution: :resolved, progress_resolved_count: 2, member_count: 2, stale_count: 0, stale_observed_at: nil}
      assert wave.core?
      assert wave.label == "W1"
    end

    test "excludes Ad Hoc from wave completion" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 2)])
      adhoc = adhoc([%{adhoc_row("9", 1) | lifecycle: :open}])
      waves = BuildOrderGridModel.build(model, adhoc).waves
      w1 = Enum.find(waves, &(&1.phase == 1))
      assert w1.completion.progress == 100
    end

    test "keeps resolved coverage and marks an aggregate partial" do
      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 4),
          node(:b, "B", "plan-graph", 1,
            status: :status_unknown,
            complexity: 1,
            progress: :unknown,
            lifecycle: %{state: :unknown, state_reason: :unknown}
          )
        ])

      grid = BuildOrderGridModel.build(model, nil)
      assert grid.overall_completion == %{progress: 100, progress_resolution: :partial, progress_resolved_count: 1, member_count: 2, stale_count: 0, stale_observed_at: nil}
      assert hd(grid.columns).core?
      assert hd(grid.columns).completion.progress_resolution == :partial
      assert hd(grid.waves).completion.progress_resolution == :partial
    end

    test "a wave and epic whose members are all terminal report resolved" do
      model =
        model([
          node(:a, "A", "plan-graph", 1,
            status: :status_completed,
            lifecycle: %{state: :closed, state_reason: :completed}
          ),
          node(:b, "B", "plan-graph", 1,
            status: :status_not_planned,
            lifecycle: %{state: :closed, state_reason: :not_planned}
          )
        ])

      grid = BuildOrderGridModel.build(model, nil)

      assert [%{completion: %{progress_resolution: :resolved}}] = grid.waves
      assert [%{completion: %{progress_resolution: :resolved}}] = grid.columns
    end
  end

  describe "build/2 last-known progress" do
    # A paused worker's projection row goes stale after it stops emitting, but
    # the percent it last reported is still known work. The grid must carry it
    # tagged as last known — not erase it into a confident resolved 0%.
    test "a stale reading keeps its percent and is tagged last known with its age" do
      model =
        model([
          node(:a, "A", "plan-graph", 1,
            status: :status_paused,
            progress: 80,
            progress_freshness: :stale,
            progress_observed_at: @stale_at,
            complexity: 3
          )
        ])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{
               progress: 80,
               progress_resolution: :resolved,
               progress_resolved_count: 1,
               member_count: 1,
               stale_count: 1,
               stale_observed_at: @stale_at
             }
    end

    test "a fresh reading carries no last-known marker" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_working, progress: 45, progress_freshness: :fresh, progress_observed_at: @stale_at)])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{progress: 45, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    # Missing activity is a different fact from a stale reading: nothing was
    # ever observed, so there is no percent to retain, nothing to age, and no
    # basis for a resolved 0% either.
    test "an open member with no reading at all stays unresolved rather than resolved zero" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_paused, progress: :unknown, progress_freshness: :unknown, progress_observed_at: nil)])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{progress: nil, progress_resolution: :unresolved, progress_resolved_count: 0, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    test "a closed member that was not completed is resolved at zero without a last-known marker" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_not_planned, progress: :unknown, lifecycle: %{state: :closed, state_reason: :not_planned})])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{progress: 0, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    # An aggregate may only claim an oldest reading when every retained reading
    # has a timestamp; one without leaves the age unknown.
    test "one stale reading without a timestamp leaves the aggregate age unknown" do
      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_paused, progress: 80, progress_freshness: :stale, progress_observed_at: @stale_at, complexity: 1),
          node(:b, "B", "plan-graph", 1, status: :status_paused, progress: 60, progress_freshness: :stale, progress_observed_at: nil, complexity: 1)
        ])

      grid = BuildOrderGridModel.build(model, nil)

      assert [%{completion: %{progress: 70, stale_count: 2, stale_observed_at: nil}}] = grid.waves
      assert %{stale_count: 2, stale_observed_at: nil} = grid.overall_completion
    end

    test "merged always outranks a stale reading and never counts as last known" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_completed, progress: 80, progress_freshness: :stale, progress_observed_at: @stale_at)])

      [card] = BuildOrderGridModel.build(model, nil).cards

      assert card.completion == %{progress: 100, progress_resolution: :resolved, progress_resolved_count: 1, member_count: 1, stale_count: 0, stale_observed_at: nil}
    end

    # The Khala shape: paused members whose rows went stale (80, 90) next to a
    # fresh row whose reading is itself stale, all open. The wave, epic, and
    # overall bars must agree with the retained percents and say how many
    # members are last known and how old the oldest reading is.
    test "wave, epic, and overall aggregates fold stale percents and report the oldest last-known reading" do
      older = DateTime.add(@stale_at, -600, :second)

      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_paused, progress: 80, progress_freshness: :stale, progress_observed_at: @stale_at, complexity: 2),
          node(:b, "B", "plan-graph", 1, status: :status_paused, progress: 90, progress_freshness: :stale, progress_observed_at: older, complexity: 3),
          node(:c, "C", "plan-graph", 1, status: :status_working, progress: 50, progress_freshness: :fresh, progress_observed_at: @stale_at, complexity: 1)
        ])

      grid = BuildOrderGridModel.build(model, nil)

      # (2*80 + 3*90 + 1*50) / 6 = 80
      expected = %{progress: 80, progress_resolution: :resolved, progress_resolved_count: 3, member_count: 3, stale_count: 2, stale_observed_at: older}
      assert [%{completion: ^expected}] = grid.waves
      assert [%{completion: ^expected}] = grid.columns
      assert grid.overall_completion == expected
    end
  end

  describe "build/2 edges" do
    test "maps edge keys to card identifiers and normalizes state" do
      model =
        model(
          [node(:a, "A", "plan-graph", 1), node(:b, "B", "plan-graph", 2)],
          [edge(:a, :b, :cleared), edge(:b, :a, :blocking)]
        )

      edges = BuildOrderGridModel.build(model, nil).edges

      assert %{source: "A", target: "B", state: "cleared"} in edges
      assert %{source: "B", target: "A", state: "blocking"} in edges
    end

    test "keeps edges planned when either mixed-pack endpoint is a draft" do
      model =
        model(
          [node(:live, "A", "plan-graph", 1), node(:draft, "B", "plan-graph", 2, planned?: true)],
          [edge(:live, :draft, :blocking)]
        )

      assert [%{source: "A", target: "B", state: "planned"}] = BuildOrderGridModel.build(model, nil).edges
    end
  end

  # --- fixtures ---------------------------------------------------------------

  defp model(nodes, edges \\ []),
    do: %AiurWeb.BuildOrderViewModel{status: :ready, nodes: nodes, edges: edges}

  defp node(key, id, lane, phase, opts \\ []) do
    status = Keyword.get(opts, :status)

    %Node{
      key: key,
      identity: nil,
      title: "Node #{id}",
      plan: %{complexity: Keyword.get(opts, :complexity, :unknown)},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: status && %Icon{key: status, text: to_string(status)},
      health: %{},
      observed_at: %{},
      provenance: %{},
      diagnostics: [],
      card: %{
        identifier: id,
        lane: lane,
        phase: phase,
        status_text: "status",
        lifecycle: Keyword.get(opts, :lifecycle, %{state: :open, state_reason: :none}),
        execution_state: :idle,
        agent_stage: nil,
        progress: Keyword.get(opts, :progress, :unknown),
        progress_freshness: Keyword.get(opts, :progress_freshness, :unknown),
        progress_observed_at: Keyword.get(opts, :progress_observed_at),
        planned?: Keyword.get(opts, :planned?, false)
      }
    }
  end

  defp edge(source_key, target_key, state) do
    %Edge{
      id: "#{source_key}-#{target_key}",
      source: nil,
      target: nil,
      source_key: source_key,
      target_key: target_key,
      kind: :native,
      state: state,
      source_connection: nil,
      text: nil,
      diagnostics: []
    }
  end

  defp adhoc(rows), do: %{status: :ready, total: length(rows), rows: rows}

  defp adhoc_row(id, phase) do
    %{
      identifier: id,
      title: "Ad hoc #{id}",
      href: nil,
      lifecycle: :open,
      phase: phase,
      complexity: 3,
      running?: false,
      progress: nil
    }
  end
end
