defmodule Aiur.Instance.SweepFilter do
  @moduledoc "Drops another instance's tickets, PRs and merge groups from an Executor sweep snapshot (#5803)."

  alias Aiur.Instance
  alias Aiur.LandingWatch.MergeQueueFailureEvidence

  @spec own(map()) :: map()
  def own(snapshot) when is_map(snapshot) do
    rules = Instance.rules()

    if rules == %Aiur.Config.Schema.Instance.Ignore{} do
      snapshot
    else
      tickets = Map.get(snapshot, :tickets) || []
      labels = Map.new(tickets, &{Map.get(&1, :number), Map.get(&1, :labels)})

      foreign_ticket? = fn ticket ->
        number = Instance.number(ticket)
        number != nil and Instance.foreign?(ticket, Map.get(labels, number), rules) and Instance.ignored(ticket, :executor_sweep)
      end

      foreign_prs = for pr <- Map.get(snapshot, :pull_requests) || [], foreign_ticket?.(Map.get(pr, :issue_number)), into: MapSet.new(), do: Map.get(pr, :number)
      base_branch = Aiur.Config.base_branch()

      snapshot
      |> update(:tickets, &(not foreign_ticket?.(Map.get(&1, :number))))
      |> update(:decisions, &(not foreign_ticket?.(Map.get(&1, :ticket))))
      |> update(:pull_requests, &(Map.get(&1, :number) not in foreign_prs))
      |> update(:merge_queue, &(Map.get(&1, :number) not in foreign_prs))
      |> update(:merge_groups, &(not foreign_group?(&1, foreign_prs, base_branch)))
    end
  end

  defp update(snapshot, key, keep?) do
    case Map.get(snapshot, key) do
      list when is_list(list) -> Map.put(snapshot, key, Enum.filter(list, keep?))
      _ -> snapshot
    end
  end

  defp foreign_group?(group, foreign_prs, base_branch) do
    group
    |> value(:head_branch)
    |> MergeQueueFailureEvidence.run_pr_numbers(base_branch)
    |> Enum.any?(&MapSet.member?(foreign_prs, &1))
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
