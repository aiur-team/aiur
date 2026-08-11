defmodule Aiur.DecisionStore.RetainedSnapshot.QueryPlan do
  @moduledoc false

  alias Aiur.Decision
  alias Aiur.DecisionStore.RetainedIndex

  @lifecycle_statuses [:deferred, :expired, :dismissed, :decided, :acknowledged, :resolved]
  @open_statuses [:open, :deferred]
  @awaiting_statuses [:open]
  @historic_statuses [:expired, :dismissed, :decided, :acknowledged, :resolved]
  # Command history as the operator reads it: everything they have finished
  # with. A deferral is finished for them — the Executor owns the answer — so it
  # belongs here and not in the queue they still have to work.
  @history_statuses [:deferred | @historic_statuses]
  @maximum_candidate_reads 1_000

  @spec build(map(), map()) :: map()
  def build(index, query) do
    candidate = candidate(index, query)

    %{
      candidate: candidate,
      matcher: &matches?(&1, query),
      max_reads: if(scan_limited?(query), do: @maximum_candidate_reads, else: :infinity),
      total: if(scan_limited?(query), do: nil, else: :gb_sets.size(candidate))
    }
  end

  @spec matches?(Decision.t(), map()) :: boolean()
  def matches?(decision, query) do
    lifecycle_match?(decision, Map.get(query, :lifecycle)) and
      ticket_match?(decision, Map.get(query, :ticket)) and
      search_match?(decision, Map.get(query, :search)) and
      optional_match?(decision.authority, Map.get(query, :authority)) and
      optional_match?(decision.blocking, Map.get(query, :blocking)) and
      kind_match?(decision.kind, Map.get(query, :kind))
  end

  defp candidate(index, %{ticket: ticket} = query) when is_binary(ticket),
    do: RetainedIndex.ticket(index, ticket, ordering(query))

  defp candidate(index, %{search: search} = query) when is_binary(search),
    do: RetainedIndex.search(index, search, ordering(query))

  defp candidate(index, %{lifecycle: :open} = query), do: union(index, @open_statuses, query)
  defp candidate(index, %{lifecycle: :awaiting} = query), do: union(index, @awaiting_statuses, query)

  defp candidate(index, %{lifecycle: lifecycle} = query) when lifecycle in @lifecycle_statuses,
    do: RetainedIndex.lifecycle(index, lifecycle, ordering(query))

  defp candidate(index, %{lifecycle: :historic} = query), do: union(index, @historic_statuses, query)
  defp candidate(index, %{lifecycle: :history} = query), do: union(index, @history_statuses, query)

  defp candidate(index, query), do: RetainedIndex.all(index, ordering(query))

  defp union(index, statuses, query) do
    statuses
    |> Enum.map(&RetainedIndex.lifecycle(index, &1, ordering(query)))
    |> Enum.reduce(:gb_sets.empty(), &:gb_sets.union/2)
  end

  defp scan_limited?(query) do
    Enum.any?([:ticket, :search, :authority, :blocking, :kind], &(not is_nil(Map.get(query, &1))))
  end

  defp lifecycle_match?(_decision, nil), do: true
  defp lifecycle_match?(decision, :open), do: decision.decision_status in @open_statuses
  defp lifecycle_match?(decision, :awaiting), do: decision.decision_status in @awaiting_statuses
  defp lifecycle_match?(decision, :historic), do: decision.decision_status in @historic_statuses
  defp lifecycle_match?(decision, :history), do: decision.decision_status in @history_statuses
  defp lifecycle_match?(decision, lifecycle), do: decision.decision_status == lifecycle
  defp ticket_match?(_decision, nil), do: true
  defp ticket_match?(decision, ticket), do: exact_match?(ticket_identifier(decision), ticket)
  defp search_match?(_decision, nil), do: true

  defp search_match?(decision, search) do
    starts_with?(decision.decision_id, search) or starts_with?(ticket_identifier(decision), search)
  end

  defp optional_match?(_actual, nil), do: true
  defp optional_match?(actual, expected), do: actual == expected
  defp kind_match?(_actual, nil), do: true
  defp kind_match?(nil, _expected), do: false
  defp kind_match?(actual, expected), do: String.downcase(String.trim(actual)) == expected
  defp starts_with?(nil, _prefix), do: false
  defp starts_with?(value, prefix), do: String.starts_with?(String.downcase(value), String.downcase(prefix))
  defp exact_match?(nil, _expected), do: false
  defp exact_match?(value, expected), do: String.downcase(value) == String.downcase(expected)
  defp ticket_identifier(%Decision{ticket: ticket}), do: ticket && Map.get(ticket, :identifier)
  defp ordering(query), do: Map.get(query, :ordering, :audit)
end
