defmodule Aiur.DecisionStore.Index do
  @moduledoc false

  alias Aiur.Decision

  @default_legacy_question_version_limit 25
  @maximum_legacy_page_limit 200
  @maximum_legacy_page_offset 1_000_000

  @spec build_decision_index(term()) :: term()
  def build_decision_index(current) do
    current
    |> Map.values()
    |> Enum.map(&recent_decision_sort_key/1)
    |> :gb_sets.from_list()
  end

  @spec update_decision_index(term(), term(), term()) :: term()
  def update_decision_index(index, prior, %Decision{} = decision) do
    updated_index = delete_decision_index(index, prior)
    :gb_sets.add(recent_decision_sort_key(decision), updated_index)
  end

  defp delete_decision_index(index, %Decision{} = decision),
    do: :gb_sets.delete_any(recent_decision_sort_key(decision), index)

  defp delete_decision_index(index, _prior), do: index

  @spec take_indexed_decisions(term(), term(), term()) :: term()
  def take_indexed_decisions(index, current, limit),
    do: take_indexed_decisions(:gb_sets.iterator(index), current, limit, [])

  defp take_indexed_decisions(_iterator, _current, 0, decisions), do: Enum.reverse(decisions)

  defp take_indexed_decisions(iterator, current, remaining, decisions) do
    case :gb_sets.next(iterator) do
      {{_resolved, _non_blocking, _urgency, _created_at, decision_id}, next_iterator} ->
        take_indexed_decisions(
          next_iterator,
          current,
          remaining - 1,
          [Map.fetch!(current, decision_id) | decisions]
        )

      :none ->
        Enum.reverse(decisions)
    end
  end

  defp recent_decision_sort_key(%Decision{} = decision) do
    {
      decision.decision_status in [:expired, :dismissed, :moot, :resolved],
      not decision.blocking,
      -urgency_rank(decision.urgency),
      -datetime_sort_key(decision.created_at),
      decision.decision_id
    }
  end

  defp urgency_rank(:critical), do: 3
  defp urgency_rank(:high), do: 2
  defp urgency_rank(:normal), do: 1
  defp urgency_rank(_urgency), do: 0

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  @spec reverse_histories(term()) :: term()
  def reverse_histories(histories) do
    Map.new(histories, fn {decision_id, history} -> {decision_id, Enum.reverse(history)} end)
  end

  @spec legacy_question_version_limit_reached?(term(), term()) :: term()
  def legacy_question_version_limit_reached?(decision, state) do
    decision.version >= state.legacy_question_version_limit
  end

  @spec legacy_question_version_limit(term()) :: term()
  def legacy_question_version_limit(opts) do
    case Keyword.get(opts, :legacy_question_version_limit, @default_legacy_question_version_limit) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_legacy_question_version_limit
    end
  end

  @spec valid_legacy_page?(term(), term()) :: term()
  def valid_legacy_page?(offset, limit)
      when offset >= 0 and offset <= @maximum_legacy_page_offset and limit >= 1 and
             limit <= @maximum_legacy_page_limit,
      do: :ok

  def valid_legacy_page?(_offset, _limit), do: {:error, :invalid_query}

  @spec legacy_query_params(term()) :: term()
  def legacy_query_params(query) do
    query
    |> Map.drop([:limit, "limit", :ordering])
    |> Map.put(:limit, 1)
  end
end
