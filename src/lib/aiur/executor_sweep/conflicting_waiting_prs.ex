defmodule Aiur.ExecutorSweep.ConflictingWaitingPrs do
  @moduledoc false

  @spec findings(map(), non_neg_integer()) :: [map()]
  def findings(snapshot, max_age_ms) do
    base_branch = Aiur.Config.base_branch()

    waiting =
      snapshot
      |> Map.get(:tickets, [])
      |> Enum.filter(fn ticket ->
        labels = value(ticket, :labels, [])
        "agent:ci-wait" in labels or "agent:human-review" in labels
      end)
      |> MapSet.new(&value(&1, :number, nil))

    snapshot
    |> Map.get(:pull_requests, [])
    |> Enum.flat_map(&finding(&1, waiting, base_branch, max_age_ms, snapshot))
  end

  defp finding(pr, waiting, base_branch, max_age_ms, snapshot) do
    issue_number = value(pr, :issue_number, nil)

    with true <- issue_number in waiting,
         "open" <- value(pr, :state, ""),
         "CONFLICTING" <- value(pr, :mergeable, nil) do
      age = get_in(snapshot, [:github_cache_ages, :pull_requests, value(pr, :number, nil)])
      fresh? = is_integer(age) and age <= max_age_ms
      verification = if fresh?, do: "verified", else: "unverified"

      [
        %{
          kind: "conflicting_waiting_pr",
          priority: 2,
          age_ms: 0,
          action:
            if(fresh?,
              do: "Merge #{base_branch} into the PR branch and resolve the conflicts.",
              else: "Verify the PR mergeability in GitHub before taking action."
            ),
          message: "Ticket ##{issue_number} is waiting while PR ##{value(pr, :number, "?")} has cached mergeable=CONFLICTING with #{base_branch}; #{verification} (cache age #{cache_age(age)}).",
          pull_request: value(pr, :number, nil),
          ticket: issue_number,
          cache_age_ms: age
        }
      ]
    else
      _not_a_conflicting_waiting_pr -> []
    end
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp cache_age(age) when is_integer(age), do: duration(age)
  defp cache_age(_), do: "unknown"

  defp duration(ms) do
    total_minutes = div(ms, 60_000)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)
    if hours > 0, do: "#{hours}h #{minutes}m", else: "#{minutes}m"
  end
end
