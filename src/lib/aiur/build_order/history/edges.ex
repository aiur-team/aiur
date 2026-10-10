defmodule Aiur.BuildOrder.History.Edges do
  @moduledoc "Historic dependency facts and numeric-id projections, without transitive walks."
  alias Aiur.Bounded
  alias Aiur.BuildOrder.{EdgeState, Lifecycle, ProviderHealth}

  @type projection :: %{deps: [String.t()], children: [String.t()], dep_states: map(), deps_missing: non_neg_integer() | nil}
  @type index :: %{optional(pos_integer()) => projection(), :complete? => boolean()}
  @type edge :: %{blocker: map(), blocked: pos_integer(), state: EdgeState.t(), order: atom(), missing: boolean() | nil, causes: [atom()]}

  @spec build(map(), map()) :: {:ok, %{edges: [edge()], by_ticket: index()}} | {:error, :unavailable}
  def build(%{rows: rows, health: %ProviderHealth{state: :healthy} = health}, repository) do
    # ponytail: full rebuild; use an incremental index if C12-T06 exceeds the 10k-row budget.
    by_ticket = Map.new(rows, fn {number, row} -> {number, empty(missing_count(row, health))} end)

    {edges, by_ticket} =
      Enum.reduce(rows, {[], by_ticket}, fn {_number, row}, acc ->
        row.blocked_by
        |> refs()
        |> Enum.uniq_by(&{String.downcase(&1.owner), String.downcase(&1.repository), &1.number})
        |> Enum.reduce(acc, fn ref, {edges, index} ->
          blocker = if Bounded.same_repository?(repository, ref), do: Map.get(rows, ref.number)
          edge = edge(row, ref, blocker, health)
          {[edge | edges], project(index, edge, blocker)}
        end)
      end)

    by_ticket = Map.new(by_ticket, fn {number, projection} -> {number, %{projection | deps: sorted_ids(projection.deps), children: sorted_ids(projection.children)}} end)
    edges = Enum.sort_by(edges, &{&1.blocked, String.downcase(&1.blocker.owner), String.downcase(&1.blocker.repository), &1.blocker.number})
    {:ok, %{edges: edges, by_ticket: Map.put(by_ticket, :complete?, health.complete?)}}
  end

  def build(_snapshot, _repository), do: {:error, :unavailable}

  @doc "Projects a number from build/2's by_ticket index, whose :complete? key governs absent rows."
  @spec to_payload(index(), pos_integer()) :: projection()
  def to_payload(by_ticket, number), do: Map.get(by_ticket, number, empty(if(by_ticket[:complete?], do: 0)))

  defp refs(:unknown), do: []
  defp refs(refs), do: refs
  defp empty(missing), do: %{deps: [], children: [], dep_states: %{}, deps_missing: missing}
  defp sorted_ids(numbers), do: numbers |> Enum.sort() |> Enum.map(&to_string/1)
  defp missing_count(%{blocked_by: refs, blocked_by_complete: true}, %{complete?: true}) when is_list(refs), do: 0
  defp missing_count(_row, _health), do: nil

  defp edge(row, ref, nil, health) do
    %{blocker: ref, blocked: row.number, state: :unknown, order: :unknown, missing: if(health.complete?, do: true), causes: if(health.complete?, do: [:not_in_index], else: [])}
  end

  defp edge(row, ref, blocker, health) do
    state = EdgeState.classify(blocker.lifecycle, health)
    order = order(row, blocker)
    causes = if blocker.lifecycle == %Lifecycle{state: :closed, state_reason: :not_planned}, do: [:blocker_not_planned], else: []
    causes = if order == :violated, do: causes ++ [:closed_before_blocker], else: causes
    causes = if ref.number == row.number, do: [:self_loop | causes], else: causes
    state = if order == :violated and state in [:cleared, :blocking], do: :terminal_unsatisfied, else: state
    %{blocker: ref, blocked: row.number, state: state, order: order, missing: false, causes: causes}
  end

  defp order(%{lifecycle: %Lifecycle{state: :closed, state_reason: :completed}} = row, blocker), do: completed_order(row, blocker)
  defp order(_row, _blocker), do: :not_closed
  defp completed_order(_row, %{lifecycle: %Lifecycle{state: :open}}), do: :violated
  defp completed_order(_row, %{lifecycle: %Lifecycle{state: :unknown}}), do: :unknown
  defp completed_order(%{end: %DateTime{} = blocked_end}, %{end: %DateTime{} = blocker_end}), do: if(DateTime.compare(blocker_end, blocked_end) == :gt, do: :violated, else: :in_order)
  defp completed_order(_row, _blocker), do: :unknown

  defp project(index, %{missing: missing, blocked: number}, nil) do
    if missing == true, do: Map.update!(index, number, &%{&1 | deps_missing: increment(&1.deps_missing)}), else: index
  end

  defp project(index, %{blocker: %{number: number}, blocked: number}, _blocker), do: index

  defp project(index, %{blocker: %{number: blocker}, blocked: blocked, state: state}, _row) do
    index
    |> Map.update!(blocked, &%{&1 | deps: [blocker | &1.deps], dep_states: Map.put(&1.dep_states, to_string(blocker), Atom.to_string(state))})
    |> Map.update!(blocker, &%{&1 | children: [blocked | &1.children]})
  end

  defp increment(nil), do: nil
  defp increment(count), do: count + 1
end
