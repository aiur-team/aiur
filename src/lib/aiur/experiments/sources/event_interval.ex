defmodule Aiur.Experiments.Sources.EventInterval do
  @moduledoc false

  alias Aiur.Events.Topic
  alias Aiur.Experiments.Observation
  alias Aiur.Experiments.Sources.Common

  @spec observations(term(), String.t(), map(), map()) :: map()
  def observations(metric, ref, window, ctx) do
    case Common.events(ref, window, ctx) do
      {:ok, events} ->
        observations = events |> Enum.group_by(& &1["unit"]) |> Enum.flat_map(fn {_unit, rows} -> interval(rows, metric.source) end)
        Common.result(Common.event_coverage(metric, ref, events, window, ctx), observations)

      {:error, reason} ->
        Common.unavailable(reason)
    end
  end

  defp interval(events, source) do
    start = Enum.find(events, &Topic.matches?(source["start"], &1["topic"]))
    finish = start && Enum.find(events, &(Topic.matches?(source["end"], &1["topic"]) and DateTime.compare(&1["at"], start["at"]) != :lt))

    if start && finish && start["unit"] do
      {:ok, observation} =
        Observation.new(%{
          "unit_id" => start["unit"],
          "value" => DateTime.diff(finish["at"], start["at"], :millisecond),
          "at" => finish["at"],
          "attrs" => Map.merge(start["attrs"] || %{}, Map.reject(finish["attrs"] || %{}, fn {_key, value} -> is_nil(value) end))
        })

      [observation]
    else
      []
    end
  end
end
