defmodule Aiur.ExecutorSweep.CacheFreshness do
  @moduledoc false
  alias Aiur.GitHub.RunnerStarvation

  @spec stale_merge_groups(map(), DateTime.t(), pos_integer(), pos_integer()) :: [map()]
  def stale_merge_groups(snapshot, now, stale_minutes, max_age_ms) do
    groups = Map.get(snapshot, :merge_groups, [])

    starvation =
      case RunnerStarvation.diagnose(groups, DateTime.to_unix(now, :millisecond), stale_minutes) do
        nil -> []
        diagnosis -> [runner_starvation(diagnosis, groups, snapshot, max_age_ms)]
      end

    stale_groups =
      Enum.flat_map(groups, fn group ->
        age = cache_age(snapshot, value(group, :id, nil))
        stale_merge_group(group, age, now, stale_minutes, max_age_ms)
      end)

    starvation ++ stale_groups
  end

  defp runner_starvation(diagnosis, groups, snapshot, max_age_ms) do
    queued = Enum.filter(groups, &(group_state(&1) == "queued"))
    cache_ages = Enum.map(queued, &cache_age(snapshot, value(&1, :id, nil)))
    verified? = Enum.all?(cache_ages, &(is_integer(&1) and &1 <= max_age_ms))
    verification = if verified?, do: "verified", else: "unverified"
    oldest_age = diagnosis.age_ms
    queued_count = diagnosis.queued_runs
    running_count = diagnosis.running_runs

    %{
      kind: "runner_starvation",
      priority: 2,
      age_ms: oldest_age,
      queued_runs: queued_count,
      running_runs: running_count,
      status_url: diagnosis.status_url,
      verification: verification,
      action: "Check GitHub Actions component status and runner availability; #{verification} queue evidence.",
      message:
        "GitHub runner starvation: #{queued_count} merge-group runs queued, #{running_count} running; oldest queued #{duration(oldest_age)}. GitHub Actions status: #{diagnosis.status_url} (#{verification})."
    }
  end

  defp stale_merge_group(group, cache_age_ms, now, stale_minutes, max_age_ms) do
    age = group_age(group, now)

    if group_state(group) in ["queued", "in_progress"] and age >= stale_minutes * 60_000 do
      [finding(group, age, cache_age_ms, max_age_ms)]
    else
      []
    end
  end

  defp finding(group, age, cache_age_ms, max_age_ms) do
    verified? = is_integer(cache_age_ms) and cache_age_ms <= max_age_ms
    verification = if verified?, do: "verified", else: "unverified"

    action =
      if verified?,
        do: "Inspect the merge-group run and start a fresh required run if needed.",
        else: "Verify this merge-group run in GitHub before taking action."

    %{
      kind: "stale_merge_group",
      priority: 5,
      age_ms: age,
      action: action,
      message: "Merge group #{value(group, :name, "?")} is #{group_state(group)} for #{duration(age)}; #{verification} (GitHub cache age: #{cache_age(cache_age_ms)}).",
      merge_group: value(group, :name, nil),
      cache_age_ms: cache_age_ms,
      verification: verification
    }
  end

  defp cache_age(snapshot, id), do: get_in(snapshot, [:github_cache_ages, :merge_group_runs, id])
  defp cache_age(age) when is_integer(age), do: duration(age)
  defp cache_age(_), do: "unknown"
  defp group_state(group), do: value(group, :state, value(group, :status, ""))
  defp group_age(group, now), do: group |> value(:started_at, nil) |> date() |> age_ms(now)
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp age_ms(%DateTime{} = started_at, now),
    do: max(DateTime.diff(now, started_at, :millisecond), 0)

  defp age_ms(_, _now), do: 0
  defp date(%DateTime{} = value), do: value
  defp date(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp date(_), do: nil

  defp duration(ms) do
    minutes = div(ms, 60_000)
    hours = div(minutes, 60)
    if hours > 0, do: "#{hours}h #{rem(minutes, 60)}m", else: "#{minutes}m"
  end
end
