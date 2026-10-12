defmodule Aiur.Experiments.Sources.EventInterval do
  @moduledoc false

  alias Aiur.Events.Topic
  alias Aiur.Experiments.Observation
  alias Aiur.Experiments.Sources.Common

  @spec observations(term(), String.t(), map(), map()) :: map()
  def observations(metric, ref, window, ctx) do
    case Common.events(ref, Map.get(ctx, :interval_window, window), ctx) do
      {:ok, events} ->
        observations = events |> Enum.group_by(& &1["unit"]) |> Enum.flat_map(fn {_unit, rows} -> interval(rows, metric.source, window, ctx) end)
        observations = Enum.filter(observations, &selected?(&1, window, ctx))
        Common.result(Common.event_coverage(metric, ref, events, window, ctx), observations)

      {:error, reason} ->
        Common.unavailable(reason)
    end
  end

  defp selected?(row, window, ctx) do
    if Map.get(ctx, :include_open, false) do
      at = if ctx[:assign_by] == "finish", do: row.finished_at || row.started_at, else: row.started_at
      Common.in_window?(at, window)
    else
      true
    end
  end

  defp interval(events, source, window, ctx) do
    start = Enum.find(events, &Topic.matches?(source["start"], &1["topic"]))
    finish = start && Enum.find(events, &(Topic.matches?(source["end"], &1["topic"]) and DateTime.compare(&1["at"], start["at"]) != :lt))

    interval_row(start, finish, window, ctx)
  end

  defp interval_row(nil, _finish, _window, _ctx), do: []
  defp interval_row(%{"unit" => nil}, _finish, _window, _ctx), do: []
  defp interval_row(start, %{} = finish, _window, _ctx), do: [observation(start, finish["at"], finish, false)]

  defp interval_row(start, nil, window, ctx) do
    if Map.get(ctx, :include_open, false), do: [observation(start, window.end, nil, true)], else: []
  end

  defp observation(start, at, finish, censored) do
    attrs = Map.merge(start["attrs"] || %{}, Map.reject(if(finish, do: finish["attrs"] || %{}, else: %{}), fn {_key, value} -> is_nil(value) end))

    {:ok, observation} =
      Observation.new(%{
        "unit_id" => start["unit"],
        "value" => DateTime.diff(at, start["at"], :millisecond),
        "at" => at,
        "started_at" => start["at"],
        "finished_at" => if(finish, do: finish["at"]),
        "censored" => censored,
        "attrs" => attrs
      })

    observation
  end
end
