defmodule AiurWeb.OperatorControlCenter.BuildOrderGridModelTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Icon
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

  describe "build/1 columns" do
    test "orders planning lanes by metadata order" do
      model = model([node(:a, "A", "platform", 1), node(:b, "B", "plan-graph", 1)])

      lanes = Enum.map(BuildOrderGridModel.build(model).columns, & &1.lane)

      assert lanes == ["plan-graph", "platform"]
    end

    test "counts cards per column" do
      model = model([node(:a, "A", "plan-graph", 1), node(:b, "B", "plan-graph", 2)])

      [%{lane: "plan-graph", count: count}] = BuildOrderGridModel.build(model).columns

      assert count == 2
    end
  end

  describe "build/1 progress and merged" do
    test "a merged (completed) card is forced to 100%" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_completed, progress: 10)])

      [card] = BuildOrderGridModel.build(model).cards

      assert card.merged
      assert card.progress == 100
      assert card.status_word == "merged"
    end

    test "unknown progress renders 0 without a bar" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_blocking, progress: :unknown)])

      [card] = BuildOrderGridModel.build(model).cards

      refute card.has_progress
      assert card.progress == 0
    end

    test "renders a planned member alongside live members" do
      model = model([node(:live, "A", "plan-graph", 1, status: :status_completed), node(:draft, "B", "plan-graph", 1, planned?: true)])

      cards = BuildOrderGridModel.build(model).cards

      assert Enum.find(cards, &(&1.id == "A")).state == :merged
      assert Enum.find(cards, &(&1.id == "B")).state == :planned
    end
  end

  describe "build/1 wave completion" do
    test "complexity-weights member completion per wave; merged counts full" do
      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 4),
          node(:b, "B", "plan-graph", 1, status: :status_working, complexity: 1, progress: 0)
        ])

      [wave] = BuildOrderGridModel.build(model).waves

      # (4*1.0 + 1*0.0) / (4 + 1) = 80%
      assert wave.pct == 80
      assert wave.label == "W1"
    end

    test "includes discovered members in wave completion and totals" do
      model =
        model([
          node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 2),
          node(:b, "B", "runtime", 1, complexity: 3, provenance: :discovered, added_at: ~U[2026-08-01 12:00:00Z])
        ])

      grid = BuildOrderGridModel.build(model)
      waves = grid.waves
      w1 = Enum.find(waves, &(&1.phase == 1))

      assert w1.pct == 40
      assert grid.overall_pct == 40
      assert grid.totals == %{baseline_total: 1, discovered_total: 1, total: 2, completed: 1}
      assert %{lane: "runtime", discovered?: true, added_at: ~U[2026-08-01 12:00:00Z]} = Enum.find(grid.cards, & &1.discovered?)
    end

    test "preserves unknown aggregate completion when any core card lacks progress" do
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
      assert grid.overall_pct == nil
      assert hd(grid.columns).core?
      assert hd(grid.columns).pct == nil
      assert hd(grid.waves).pct == nil
    end
  end

  describe "build/1 edges" do
    test "maps edge keys to card identifiers and normalizes state" do
      model =
        model(
          [node(:a, "A", "plan-graph", 1), node(:b, "B", "plan-graph", 2)],
          [edge(:a, :b, :cleared), edge(:b, :a, :blocking)]
        )

      edges = BuildOrderGridModel.build(model).edges

      assert %{source: "A", target: "B", state: "cleared"} in edges
      assert %{source: "B", target: "A", state: "blocking"} in edges
    end

    test "keeps edges planned when either mixed-pack endpoint is a draft" do
      model =
        model(
          [node(:live, "A", "plan-graph", 1), node(:draft, "B", "plan-graph", 2, planned?: true)],
          [edge(:live, :draft, :blocking)]
        )

      assert [%{source: "A", target: "B", state: "planned"}] = BuildOrderGridModel.build(model).edges
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
        planned?: Keyword.get(opts, :planned?, false),
        provenance: Keyword.get(opts, :provenance, :planned),
        added_at: Keyword.get(opts, :added_at)
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
end
