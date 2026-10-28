defmodule Aiur.Orchestrator.SpendCap.Evaluation do
  @moduledoc false

  alias Aiur.Orchestrator.SpendCap.Record

  @spec refresh(Record.t(), map(), DateTime.t()) :: {:active | :unavailable | :reached, Record.t()}
  def refresh(%Record{state: :budget_exhausted} = record, _usage, _now), do: {:reached, record}

  def refresh(%Record{} = record, %{state: :unavailable}, _now) do
    {:unavailable, %{record | state: :unavailable, spent: nil, coverage: %{}, authority: %{}}}
  end

  def refresh(%Record{} = record, usage, %DateTime{} = now) when is_map(usage) do
    with %{api_equivalent_estimate: estimate} when is_map(estimate) <- usage,
         rollup when is_map(rollup) <- Map.get(estimate, :rollup),
         %Decimal{} = spent <- Map.get(rollup, "USD") do
      updated = %{
        record
        | state: :active,
          end_state: nil,
          spent: spent,
          coverage: Map.get(estimate, :coverage, %{}),
          authority: Map.get(usage, :authority, %{})
      }

      if Decimal.compare(spent, record.cap) in [:eq, :gt] do
        {:reached,
         %{
           updated
           | state: :budget_exhausted,
             end_state: :budget_exhausted,
             reached_at: record.reached_at || now,
             effects: %{stop: :pending, event: :pending, tracker_transition: :pending}
         }}
      else
        {:active, updated}
      end
    else
      _other -> {:unavailable, %{record | state: :unavailable, spent: nil, coverage: %{}, authority: %{}}}
    end
  end
end
