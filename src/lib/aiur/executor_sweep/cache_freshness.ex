defmodule Aiur.ExecutorSweep.CacheFreshness do
  @moduledoc false

  @spec stale_merge_groups(map(), DateTime.t(), pos_integer(), pos_integer()) :: [map()]
  def stale_merge_groups(snapshot, now, stale_minutes, max_age_ms) do
    snapshot
    |> Map.get(:merge_groups, [])
    |> Enum.flat_map(&stale_merge_group(&1, cache_age(snapshot), now, stale_minutes, max_age_ms))
  end

  defp stale_merge_group(group, cache_age_ms, now, stale_minutes, max_age_ms) do
    age = group_age(group, now)

    if value(group, :state, "") in ["queued", "in_progress"] and age >= stale_minutes * 60_000 and fresh?(cache_age_ms, max_age_ms) do
      [finding(group, age, cache_age_ms)]
    else
      []
    end
  end

  defp finding(group, age, cache_age_ms) do
    %{
      kind: "stale_merge_group",
      priority: 5,
      age_ms: age,
      action: "Inspect the merge-group run and start a fresh required run if needed.",
      message: "Merge group #{value(group, :name, "?")} is #{value(group, :state, "stale")} for #{duration(age)} (GitHub cache age: #{duration(cache_age_ms)}).",
      merge_group: value(group, :name, nil),
      cache_age_ms: cache_age_ms
    }
  end

  defp cache_age(snapshot), do: get_in(snapshot, [:github_cache_ages, :landing_merge_group_runs])
  defp fresh?(age, max_age_ms), do: is_integer(age) and age <= max_age_ms
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
