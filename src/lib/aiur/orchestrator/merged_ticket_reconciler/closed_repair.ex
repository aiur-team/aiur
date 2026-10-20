defmodule Aiur.Orchestrator.MergedTicketReconciler.ClosedRepair do
  @moduledoc false

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{State, TrackerTasks}

  @max_repairs_per_poll 5
  @stale_merge_after_seconds 24 * 60 * 60

  @spec reconcile(State.t(), [Issue.t()], [RecentMerge.t()], DateTime.t(), keyword(), function(), function()) :: State.t()
  def reconcile(state, issues, merges, now, opts, record_fun, repair_fun) do
    open_ids = MapSet.new(issues, & &1.identifier)

    merges
    |> Enum.filter(&recent_attributed_merge?(&1, now))
    |> Enum.reject(&(MapSet.member?(open_ids, &1.ticket_id) or checked?(state, &1)))
    |> Enum.uniq_by(& &1.ticket_id)
    |> Enum.take(@max_repairs_per_poll)
    |> Enum.reduce(state, &start_repair(&2, &1, opts, record_fun, repair_fun))
  end

  defp start_repair(state, merge, opts, record_fun, repair_fun) do
    id = merge.ticket_id
    fetch_fun = Keyword.get(opts, :fetch_issue_states_fun, &Aiur.Tracker.fetch_issue_states_by_ids_conditional/2)
    cache = Map.take(state.merged_ticket_issue_cache, [id])

    TrackerTasks.run(state, {:merged_closed_repair, id}, fn -> fetch_fun.([id], cache) end, fn current, result ->
      apply_result(current, merge, result, opts, record_fun, repair_fun)
    end)
  end

  defp apply_result(state, merge, {:ok, [issue], cache}, opts, record_fun, repair_fun) do
    state = cache_result(state, merge.ticket_id, cache)

    cond do
      checked?(state, merge) -> state
      not closed?(issue) -> state
      issue.state_labels in [nil, []] -> repair_fun.(state, issue, merge, opts)
      true -> record_fun.(state, issue, merge)
    end
  end

  defp apply_result(state, merge, {:error, _reason, cache}, _opts, _record_fun, _repair_fun),
    do: cache_result(state, merge.ticket_id, cache)

  defp apply_result(state, _merge, _result, _opts, _record_fun, _repair_fun), do: state

  defp cache_result(state, _id, nil), do: state
  defp cache_result(state, id, cache), do: %{state | merged_ticket_issue_cache: Map.merge(state.merged_ticket_issue_cache, Map.take(cache, [id]))}

  defp closed?(%Issue{state: state}), do: String.downcase(to_string(state || "")) == "closed"

  defp checked?(%State{} = state, %RecentMerge{ticket_id: id, id: merge_id}),
    do: MapSet.member?(state.merged_ticket_reconciliations, {id, merge_id})

  defp recent_attributed_merge?(%RecentMerge{ticket_id: id, merged_by: actor, merged_at: %DateTime{} = at}, now)
       when is_binary(id) and is_binary(actor) and actor != "" do
    DateTime.diff(now, at, :second) <= @stale_merge_after_seconds
  end

  defp recent_attributed_merge?(_, _), do: false
end
