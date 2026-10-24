defmodule Aiur.ExecutorSweep.CacheFreshness do
  @moduledoc false

  @spec stale_merge_groups(map(), DateTime.t(), pos_integer(), pos_integer()) :: [map()]
  def stale_merge_groups(snapshot, now, stale_minutes, max_age_ms) do
    snapshot
    |> Map.get(:merge_groups, [])
    |> Enum.reject(&settled?(&1, get_in(snapshot, [:github_cache_ages, :merge_group_evidence]), max_age_ms))
    |> Enum.flat_map(fn group ->
      age = cache_age(snapshot, value(group, :id, nil))
      stale_merge_group(group, age, now, stale_minutes, max_age_ms)
    end)
  end

  # Fresh LandingWatch evidence overrides MainWatch's run status, which survives failed polls (#5738).
  defp settled?(group, %{} = evidence, max_age_ms) do
    run = get_in(evidence, [:runs, value(group, :id, nil)])

    match?(%{status: "completed"}, run) or unlisted?(run, Map.get(evidence, :active_listing_age_ms), max_age_ms) or
      ref_gone?(value(group, :head_branch, nil), Map.get(evidence, :refs), max_age_ms)
  end

  defp settled?(_group, _evidence, _max_age_ms), do: false

  defp unlisted?(run, listing_age, max_age_ms) when is_integer(listing_age) and listing_age <= max_age_ms,
    do: not (is_map(run) and run.age_ms <= max_age_ms)

  defp unlisted?(_run, _listing_age, _max_age_ms), do: false

  defp ref_gone?(head_branch, %{refs: refs, age_ms: age}, max_age_ms) when is_binary(head_branch) and age <= max_age_ms,
    do: "refs/heads/#{head_branch}" not in refs

  defp ref_gone?(_head_branch, _refs, _max_age_ms), do: false

  defp stale_merge_group(group, cache_age_ms, now, stale_minutes, max_age_ms) do
    age = group_age(group, now)

    if value(group, :state, "") in ["queued", "in_progress"] and age >= stale_minutes * 60_000 do
      [finding(group, age, cache_age_ms, max_age_ms)]
    else
      []
    end
  end

  defp finding(group, age, cache_age_ms, max_age_ms) do
    verified? = is_integer(cache_age_ms) and cache_age_ms <= max_age_ms
    verification = if verified?, do: "verified", else: "unverified"
    action = if verified?, do: "Inspect the merge-group run and start a fresh required run if needed.", else: "Verify this merge-group run in GitHub before taking action."

    %{
      kind: "stale_merge_group",
      priority: 5,
      age_ms: age,
      action: action,
      message: "Merge group #{value(group, :name, "?")} is #{value(group, :state, "stale")} for #{duration(age)}; #{verification} (GitHub cache age: #{cache_age(cache_age_ms)}).",
      merge_group: value(group, :name, nil),
      cache_age_ms: cache_age_ms,
      verification: verification
    }
  end

  defp cache_age(snapshot, id), do: get_in(snapshot, [:github_cache_ages, :merge_group_runs, id])
  defp cache_age(age) when is_integer(age), do: duration(age)
  defp cache_age(_), do: "unknown"
  defp group_age(group, now), do: group |> value(:started_at, nil) |> date() |> age_ms(now)
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp age_ms(%DateTime{} = started_at, now), do: max(DateTime.diff(now, started_at, :millisecond), 0)
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
