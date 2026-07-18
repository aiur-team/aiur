defmodule Aiur.CurrentRunProjections.SourceFallback do
  @moduledoc false

  alias Aiur.CurrentRunProjection.Value

  @spec resolve(map(), map()) :: {map(), map()}
  def resolve(results, previous) do
    Enum.reduce(results, {%{}, %{}}, fn {key, result}, {sources, availability} ->
      case result do
        {:ok, value} -> {Map.put(sources, key, value), Map.put(availability, key, true)}
        {:error, _reason} -> {Map.put(sources, key, fallback(key, previous)), Map.put(availability, key, false)}
      end
    end)
  end

  defp fallback(:run, previous), do: previous |> source(:run, %{}) |> Map.put(:valid?, false)

  defp fallback(:membership, previous) do
    previous
    |> source(:membership, %{})
    |> Map.put(:health, {:unavailable, :read_failed})
    |> Map.put(:freshness, %{status: :stale})
    |> Map.put_new(:members, [])
  end

  defp fallback(:status, previous) do
    previous
    |> source(:status, %{})
    |> Map.put_new(:running, [])
    |> Map.put_new(:retrying, [])
    |> Map.put_new(:idle, [])
    |> Map.put(:health, :unavailable)
    |> Map.put(:freshness, :stale)
  end

  defp fallback(:status_facts, previous), do: source(previous, :status_facts, [])

  defp fallback(:activity, previous) do
    activity = source(previous, :activity, %{entries: []})
    entries = activity |> Value.get(:entries, []) |> List.wrap() |> Enum.map(&stale_activity/1)

    activity
    |> Map.put(:entries, entries)
    |> Map.put(:health, :unavailable)
    |> Map.put(:freshness, :stale)
  end

  defp fallback(:merges, previous) do
    previous
    |> source(:merges, %{merges: []})
    |> Map.put(:health, {:unavailable, :read_failed})
  end

  defp fallback(:configured_repository, _previous),
    do: {:error, :configured_repository_unavailable}

  defp stale_activity(entry) when is_map(entry) do
    Map.update(entry, :progress, %{status: :unknown}, fn
      progress when is_map(progress) -> Map.put(progress, :freshness, :stale)
      _progress -> %{status: :unknown}
    end)
  end

  defp stale_activity(_entry), do: %{identity: nil, progress: %{status: :unknown}}
  defp source(previous, key, default), do: Value.get(previous, key, default)
end
