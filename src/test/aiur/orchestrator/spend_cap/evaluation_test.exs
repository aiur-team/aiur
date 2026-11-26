defmodule Aiur.Orchestrator.SpendCap.EvaluationTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.SpendCap.{Evaluation, Record}
  alias Aiur.TestSupport.GroupedScopes, as: GS

  test "reaching the cap produces the distinct budget_exhausted end state" do
    record = Record.new!(GS.identity(5693), "1.25", ~U[2026-10-24 20:00:00Z])

    assert {:reached, reached} =
             Evaluation.refresh(
               record,
               usage("1.25"),
               ~U[2026-10-24 20:01:00Z]
             )

    assert reached.state == :budget_exhausted
    assert reached.end_state == :budget_exhausted
    assert reached.spent == Decimal.new("1.25")
    assert reached.reached_at == ~U[2026-10-24 20:01:00Z]
  end

  test "known spend below the cap stays active and preserves partial coverage" do
    record = Record.new!(GS.identity(5693), "2.00", ~U[2026-10-24 20:00:00Z])
    usage = usage("1.25", %{status: :partial, known: 2, unknown: 1, reasons: [:unknown_model]})

    assert {:active, active} = Evaluation.refresh(record, usage, ~U[2026-10-24 20:01:00Z])
    assert active.state == :active
    assert active.end_state == nil
    assert active.coverage == usage.api_equivalent_estimate.coverage
  end

  test "an unavailable projection never invents zero spend" do
    record = Record.new!(GS.identity(5693), "2.00", ~U[2026-10-24 20:00:00Z])

    assert {:unavailable, unavailable} =
             Evaluation.refresh(record, %{state: :unavailable}, ~U[2026-10-24 20:01:00Z])

    assert unavailable.spent == nil
    assert unavailable.state == :unavailable
  end

  defp usage(amount, coverage \\ %{status: :complete, known: 1, unknown: 0, reasons: []}) do
    %{
      state: :known,
      authority: %{schema_version: 1, aggregate_generation: 3, source_position: 8, source_generation: 2, price_table_revision: "prices-v1"},
      api_equivalent_estimate: %{rollup: %{"USD" => Decimal.new(amount)}, coverage: coverage}
    }
  end
end
