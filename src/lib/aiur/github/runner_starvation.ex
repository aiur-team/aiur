defmodule Aiur.GitHub.RunnerStarvation do
  @moduledoc false

  @queue_bound 10
  @actions_status_url "https://www.githubstatus.com/#components"

  @spec diagnose(list(map()), integer(), pos_integer()) :: map() | nil
  def diagnose(groups, now_ms, stale_minutes) do
    queued = Enum.filter(groups, &(run_state(&1) == "queued"))
    running_count = Enum.count(groups, &(run_state(&1) == "in_progress"))
    oldest_queued_age = queued |> Enum.map(&age_ms(&1, now_ms)) |> Enum.max(fn -> 0 end)

    queue_pressure? = running_count == 0 or length(queued) > running_count * 2
    starvation_evidence? = length(queued) > @queue_bound or oldest_queued_age >= stale_minutes * 60_000

    if queued != [] and queue_pressure? and starvation_evidence? do
      %{
        queued_runs: length(queued),
        running_runs: running_count,
        age_ms: oldest_queued_age,
        status_url: @actions_status_url
      }
    end
  end

  defp run_state(group), do: value(group, :state, value(group, :status, ""))

  defp age_ms(group, now_ms) do
    case value(group, :started_at, nil) do
      %DateTime{} = started_at -> max(now_ms - DateTime.to_unix(started_at, :millisecond), 0)
      timestamp when is_integer(timestamp) -> max(now_ms - timestamp, 0)
      timestamp when is_binary(timestamp) -> parse_time(timestamp, now_ms)
      _ -> 0
    end
  end

  defp parse_time(timestamp, now_ms) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, started_at, _offset} -> max(now_ms - DateTime.to_unix(started_at, :millisecond), 0)
      _ -> 0
    end
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
