defmodule Aiur.Experiments.Sources.EventCount do
  @moduledoc false

  alias Aiur.Events.Topic
  alias Aiur.Experiments.Observation
  alias Aiur.Experiments.Sources.Common

  @spec observations(term(), String.t(), map(), map()) :: map()
  def observations(metric, ref, window, ctx) do
    case Common.events(ref, window, ctx) do
      {:ok, events} ->
        coverage = Common.event_coverage(metric, ref, events, window, ctx)
        matching = Enum.filter(events, &Topic.matches?(metric.source["match"], &1["topic"]))
        Common.result(coverage, counts(matching, metric.source, window, coverage))

      {:error, reason} ->
        Common.unavailable(reason)
    end
  end

  defp counts(events, %{"per" => per}, window, coverage) do
    seconds = if per == "day", do: 86_400, else: 3_600
    groups = Enum.group_by(events, &bucket(&1["at"], seconds))
    first = bucket(window.start, seconds)
    last = bucket(DateTime.add(window.end, -1, :microsecond), seconds)
    keys = if coverage.state == :captured, do: Enum.to_list(first..last//seconds), else: Map.keys(groups) |> Enum.sort()

    Enum.map(keys, fn key -> observation(Integer.to_string(key), length(Map.get(groups, key, [])), DateTime.from_unix!(key), %{}) end)
  end

  defp counts(events, _source, _window, _coverage) do
    events
    |> Enum.reject(&is_nil(&1["unit"]))
    |> Enum.group_by(& &1["unit"])
    |> Enum.map(fn {unit, rows} -> observation(unit, length(rows), List.last(rows)["at"], List.last(rows)["attrs"] || %{}) end)
  end

  defp bucket(at, seconds), do: div(DateTime.to_unix(at), seconds) * seconds

  defp observation(unit, value, at, attrs) do
    {:ok, observation} = Observation.new(%{"unit_id" => unit, "value" => value, "at" => at, "attrs" => attrs})
    observation
  end
end
