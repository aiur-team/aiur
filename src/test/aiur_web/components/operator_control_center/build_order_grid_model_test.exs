defmodule AiurWeb.OperatorControlCenter.BuildOrderGridModelTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Icon
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderGridModel

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
      assert card.progress == 100
      assert card.status_word == "merged"
    end

    test "a closed ad hoc row is merged at 100%" do
      adhoc = adhoc([%{adhoc_row("9", 1) | lifecycle: :closed, progress: nil}])

      [card] = BuildOrderGridModel.build(model([]), adhoc).cards

      assert card.merged
      assert card.progress == 100
    end

    test "unknown progress renders 0 without a bar" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_blocking, progress: :unknown)])

      [card] = BuildOrderGridModel.build(model, nil).cards

      refute card.has_progress
      assert card.progress == 0
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
      assert wave.pct == 80
      assert wave.core?
      assert wave.label == "W1"
    end

    test "excludes Ad Hoc from wave completion" do
      model = model([node(:a, "A", "plan-graph", 1, status: :status_completed, complexity: 2)])
      adhoc = adhoc([%{adhoc_row("9", 1) | lifecycle: :open}])

      waves = BuildOrderGridModel.build(model, adhoc).waves
      w1 = Enum.find(waves, &(&1.phase == 1))

      # Only the core merged card counts → 100%, ad hoc ignored.
      assert w1.pct == 100
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
        lifecycle: %{state: :open, state_reason: :none},
        execution_state: :idle,
        agent_stage: nil,
        progress: Keyword.get(opts, :progress, :unknown)
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
