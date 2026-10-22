defmodule Aiur.Instance.SweepFilter do
  @moduledoc "Drops another instance's tickets, PRs and merge groups from an Executor sweep snapshot (#5803)."

  alias Aiur.Instance

  @spec own(map()) :: map()
  def own(snapshot) when is_map(snapshot) do
    rules = Instance.rules()

    if rules == %Aiur.Config.Schema.Instance.Ignore{} do
      snapshot
    else
      tickets = Map.get(snapshot, :tickets) || []
      labels = Map.new(tickets, &{Map.get(&1, :number), Map.get(&1, :labels)})
      foreign_ticket? = fn number -> number != nil and Instance.foreign?(number, Map.get(labels, number), rules) and Instance.ignored(number, :executor_sweep) end
      foreign_prs = for pr <- Map.get(snapshot, :pull_requests) || [], foreign_ticket?.(Map.get(pr, :issue_number)), into: MapSet.new(), do: Map.get(pr, :number)

      snapshot
      |> update(:tickets, &(not foreign_ticket?.(Map.get(&1, :number))))
      |> update(:pull_requests, &(Map.get(&1, :number) not in foreign_prs))
      |> update(:merge_queue, &(Map.get(&1, :number) not in foreign_prs))
      |> update(:merge_groups, &(group_pr(&1) not in foreign_prs))
    end
  end

  defp update(snapshot, key, keep?) do
    case Map.get(snapshot, key) do
      list when is_list(list) -> Map.put(snapshot, key, Enum.filter(list, keep?))
      _ -> snapshot
    end
  end

  # Merge-group refs read `gh-readonly-queue/<base>/pr-<number>-<sha>`.
  defp group_pr(group) do
    with name when is_binary(name) <- Map.get(group, :name, Map.get(group, "name")),
         [_, number] <- Regex.run(~r{/pr-(\d+)-}, name) do
      String.to_integer(number)
    else
      _ -> nil
    end
  end
end
