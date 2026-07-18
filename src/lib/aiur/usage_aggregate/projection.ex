defmodule Aiur.UsageAggregate.Projection do
  @moduledoc false

  # Pure, reproducible fold of DASH-009 ordered accepted deltas into exact
  # multidimensional aggregate cells. Application is idempotent by source
  # position: a delta already reflected in `source_position` is skipped, so
  # duplicate projection delivery or a crash/replay can never inflate totals.

  alias Aiur.UsageAggregate.Key
  alias Aiur.UsageEnvelope.ExactMoney

  @coverage_reasons [
    :missing_trusted_occurrence_time,
    :unknown_relationship,
    :contradictory_relationship,
    :missing_historic_relationship_revision,
    :partial_update,
    :untrusted_account_generation,
    :unknown_account_generation
  ]

  defstruct cells: %{},
            source_position: 0,
            source_generation: 0,
            generation: 0,
            coverage: %{folded_records: 0, partial_records: 0, reasons: MapSet.new()}

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Seeds a projection from a DASH-025 compacted-coverage floor: the exact merged
  cells of the retired position range at `source_position`. Folding the retained
  raw above the floor reproduces the full pre-compaction projection. An empty
  floor is equivalent to `new/0`, so a non-retired rebuild is unchanged.
  """
  @spec seed(%{
          source_position: non_neg_integer(),
          source_generation: non_neg_integer(),
          cells: map(),
          coverage: map()
        }) :: t()
  def seed(%{source_position: position, source_generation: generation, cells: cells, coverage: coverage})
      when is_integer(position) and position >= 0 and is_map(cells) and is_map(coverage) do
    %__MODULE__{cells: cells, source_position: position, source_generation: generation, generation: 0, coverage: coverage}
  end

  @doc """
  Folds one ordered replay record. Records at or before `source_position` are
  ignored; a record must advance the position by exactly consuming the next
  ledger delta the caller supplied in order.
  """
  @spec apply_record(t(), map()) :: t()
  def apply_record(%__MODULE__{} = projection, %{position: position} = record)
      when is_integer(position) and position > 0 do
    if position <= projection.source_position do
      projection
    else
      fold(projection, record)
    end
  end

  # A record without a valid positive ledger position is malformed input the
  # ledger never emits; skip it rather than corrupting the fold.
  def apply_record(%__MODULE__{} = projection, _record), do: projection

  @doc "Folds an ordered batch, preserving idempotency for each position."
  @spec apply_records(t(), [map()]) :: t()
  def apply_records(%__MODULE__{} = projection, records) when is_list(records) do
    Enum.reduce(records, projection, &apply_record(&2, &1))
  end

  @spec cell_count(t()) :: non_neg_integer()
  def cell_count(%__MODULE__{cells: cells}), do: map_size(cells)

  defp fold(projection, record) do
    cells =
      record
      |> Key.cells()
      |> Enum.reduce(projection.cells, fn {cell, value}, acc -> add_cell(acc, cell, value) end)

    %{
      projection
      | cells: cells,
        source_position: record.position,
        source_generation: max(projection.source_generation, record.generation),
        generation: projection.generation + 1,
        coverage: accumulate_coverage(projection.coverage, record)
    }
  end

  defp add_cell(cells, cell, value), do: Map.update(cells, cell, value, &add_value(&1, value))

  defp add_value(%Decimal{} = left, %Decimal{} = right), do: Decimal.add(left, right)
  defp add_value(left, right) when is_integer(left) and is_integer(right), do: left + right

  defp accumulate_coverage(coverage, record) do
    reasons = record.envelope.coverage_reasons

    %{
      folded_records: coverage.folded_records + 1,
      partial_records: coverage.partial_records + if(partial?(record), do: 1, else: 0),
      reasons: MapSet.union(coverage.reasons, MapSet.new(Enum.filter(reasons, &(&1 in @coverage_reasons))))
    }
  end

  defp partial?(record) do
    record.envelope.update_kind == :partial or record.envelope.coverage_reasons != [] or
      partial_cost?(record.delta.cost)
  end

  defp partial_cost?(%ExactMoney{coverage: coverage}), do: coverage in [:partial, :unknown]
  defp partial_cost?(_cost), do: false
end
