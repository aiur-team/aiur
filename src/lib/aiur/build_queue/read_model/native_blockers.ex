defmodule Aiur.BuildQueue.ReadModel.NativeBlockers do
  @moduledoc false

  @doc "Returns cached native blocker facts, refreshing entries the cache cannot answer."
  @spec read(map(), map(), module() | nil, MapSet.t(String.t())) :: map()
  def read(document, observations, tracker, terminal_states) do
    build_order_ids =
      for item <- document.items,
          queue = Enum.find(document.queues, &(&1.id == item.queue_id)),
          queue && queue.kind == :build_order,
          do: item.issue_id

    ids = document.items |> Enum.map(& &1.issue_id) |> Enum.uniq() |> Enum.reject(&(&1 in build_order_ids))

    Map.new(ids, &{&1, blocker_result(&1, observations, tracker, terminal_states)})
    |> Map.reject(fn {_id, result} -> result == :skip end)
  end

  defp blocker_result(id, observations, tracker, terminal_states) do
    issue = %Aiur.Issue{id: id, identifier: id, title: "", state: "todo"}

    case cached_or_hydrated_blockers(issue, tracker) do
      {:ok, hydrated} -> {:ok, Enum.map(hydrated.blocked_by, &blocker(&1, observations, terminal_states))}
      {:error, :cache_miss} -> {:unknown, :blockers_not_observed}
      {:error, :unsupported} -> :skip
      {:error, reason} -> {:unknown, unknown_reason(reason)}
      :skip -> :skip
    end
  end

  # The read model renders this reason into a string, so collapse it here: a tracker
  # error tuple (a budget hold carries maps and DateTimes) crashed the queue server.
  defp unknown_reason(reason) when is_atom(reason), do: reason
  defp unknown_reason({:github, :local_hold, _hold}), do: :github_budget_hold
  defp unknown_reason({:aiur, :locally_held, _hold}), do: :github_budget_hold
  defp unknown_reason(_reason), do: :unknown

  defp cached_or_hydrated_blockers(issue, tracker) do
    if tracker && Code.ensure_loaded?(tracker) && function_exported?(tracker, :cached_blocked_by, 1) do
      hydrate_cached_miss(issue, tracker.cached_blocked_by(issue), tracker)
    else
      :skip
    end
  end

  defp hydrate_cached_miss(issue, {:error, :cache_miss}, tracker) do
    if function_exported?(tracker, :hydrate_blocked_by, 1), do: tracker.hydrate_blocked_by(issue), else: {:error, :cache_miss}
  end

  defp hydrate_cached_miss(_issue, result, _tracker), do: result

  defp blocker(%{identifier: number, state: state}, observations, terminal_states) do
    terminal? = is_binary(state) and MapSet.member?(terminal_states, String.downcase(String.trim(state)))
    open? = not match?(%{open?: false}, Map.get(observations, to_string(number))) and not terminal?

    %{number: String.to_integer(to_string(number)), state: state, open?: open?}
  end

  defp blocker(%{identifier: number}, _observations, _terminal_states),
    do: %{number: String.to_integer(to_string(number)), state: nil, open?: true}

  defp blocker(_blocker, _observations, _terminal_states), do: %{number: nil, state: nil, open?: true}
end
