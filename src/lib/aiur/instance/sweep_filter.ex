defmodule Aiur.Instance.SweepFilter do
  @moduledoc "Drops another instance's tickets, PRs and merge groups from an Executor sweep snapshot (#5803)."

  require Logger

  alias Aiur.Instance

  @spec own(map()) :: map()
  def own(snapshot) when is_map(snapshot) do
    case Instance.rules_result() do
      {:ok, rules} -> own(snapshot, rules)
      {:error, reason} -> unavailable(snapshot, reason)
    end
  end

  defp own(snapshot, %Aiur.Config.Schema.Instance.Ignore{tickets: [], labels: [], label_prefixes: []}), do: snapshot

  defp own(snapshot, rules) do
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

  defp unavailable(snapshot, reason) do
    Logger.warning("instance.ignore unavailable; suppressing ticket-scoped Executor sweep findings: #{inspect(reason)}")

    Enum.reduce([:tickets, :decisions, :pull_requests, :merge_queue, :merge_groups], snapshot, fn key, acc ->
      case Map.get(acc, key) do
        rows when is_list(rows) -> Map.put(acc, key, [])
        _ -> acc
      end
    end)
  end

  defp update(snapshot, key, keep?) do
    case Map.get(snapshot, key) do
      list when is_list(list) -> Map.put(snapshot, key, Enum.filter(list, keep?))
      _ -> snapshot
    end
  end

  defp foreign_group?(group, foreign_prs, base_branch) do
    case value(group, :head_branch) do
      branch when is_binary(branch) ->
        merge_group_contains_foreign_pr?(branch, foreign_prs, base_branch)

      _ ->
        false
    end
  end

  defp merge_group_contains_foreign_pr?(branch, foreign_prs, base_branch) do
    prefix = "gh-readonly-queue/#{base_branch}/"

    String.starts_with?(branch, prefix) and
      Regex.scan(~r/pr-(\d+)-/, branch, capture: :all_but_first)
      |> List.flatten()
      |> Enum.any?(fn number -> MapSet.member?(foreign_prs, String.to_integer(number)) end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
