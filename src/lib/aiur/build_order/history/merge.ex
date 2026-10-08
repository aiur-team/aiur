defmodule Aiur.BuildOrder.History.Merge do
  @moduledoc false
  alias Aiur.BuildOrder.History.Row
  @earliest [:in_progress_at, :dispatched_at]
  @latest [:last_closed_at, :close_observed_at, :reopened_at, :merged_at]
  @last [:start, :start_source, :end, :end_source, :clamped, :agent_model, :agent_effort]

  @spec merge(Row.t() | nil, Row.event()) :: {:changed, Row.t()} | :unchanged
  def merge(old, event) do
    row = old || %Row{number: event.number, observed_at: event.observed_at}
    late? = compare(Map.get(event.fields, :updated_at), row.updated_at) == :lt
    newer? = newer?(row, event)
    merged = Enum.reduce(event.fields, row, fn {key, value}, acc -> Map.put(acc, key, value(key, value, row, event, late?, newer?)) end)
    merged = %{merged | observed_at: extreme(row.observed_at, event.observed_at, :latest), sources: Enum.sort(Enum.uniq(row.sources ++ [event.source]))}
    if merged == old, do: :unchanged, else: {:changed, merged}
  end

  defp value(:pr_number, value, row, event, late?, _newer?) do
    winner = value(:merged_at, Map.get(event.fields, :merged_at, :unknown), row, event, late?, false)
    incoming = Map.get(event.fields, :merged_at, :unknown)
    if (row.pr_number == :unknown or not late?) and winner == incoming and (winner != row.merged_at or row.pr_number == :unknown), do: value, else: row.pr_number
  end

  defp value(key, value, row, _event, true, _newer?) when key != :dispatched_at,
    do: if(unknown?(Map.fetch!(row, key)), do: value, else: Map.fetch!(row, key))

  defp value(key, value, row, _event, _late?, _newer?) when key in @earliest, do: extreme(Map.fetch!(row, key), value, :earliest)
  defp value(key, value, row, _event, _late?, _newer?) when key in @latest, do: extreme(Map.fetch!(row, key), value, :latest)
  defp value(key, value, row, _event, _late?, _newer?) when key in [:label_events, :sub_issues_added], do: union(key, Map.fetch!(row, key), value)

  defp value(key, value, row, event, _late?, _newer?) when key in @last,
    do: replace(Map.fetch!(row, key), value, DateTime.compare(event.observed_at, row.observed_at) != :lt)

  defp value(key, value, row, _event, _late?, newer?), do: replace(Map.fetch!(row, key), value, newer?)

  defp replace(%Aiur.BuildOrder.Lifecycle{state: :unknown, state_reason: :unknown}, value, _newer?), do: value
  defp replace(:unknown, value, _newer?), do: value
  defp replace(_old, value, true), do: value
  defp replace(old, _value, false), do: old

  defp unknown?(:unknown), do: true
  defp unknown?(%Aiur.BuildOrder.Lifecycle{state: :unknown, state_reason: :unknown}), do: true
  defp unknown?(_value), do: false

  defp newer?(row, event) do
    case compare(Map.get(event.fields, :updated_at), row.updated_at) do
      :gt -> true
      :lt -> false
      _ -> DateTime.compare(event.observed_at, row.observed_at) != :lt
    end
  end

  defp compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare(_a, _b), do: :unknown

  defp extreme(%DateTime{} = a, %DateTime{} = b, direction) do
    wins = if direction == :earliest, do: :lt, else: :gt
    if DateTime.compare(b, a) == wins, do: b, else: a
  end

  defp extreme(%DateTime{} = a, _b, _direction), do: a
  defp extreme(_a, %DateTime{} = b, _direction), do: b
  defp extreme(:none, _b, _direction), do: :none
  defp extreme(_a, :none, _direction), do: :none
  defp extreme(_a, _b, _direction), do: :unknown

  # ponytail: no per-issue event cap; add one if an issue exceeds 500 events.
  defp union(_key, old, :unknown), do: old

  defp union(key, old, incoming) do
    (if(old == :unknown, do: [], else: old) ++ incoming)
    |> Enum.uniq_by(fn item -> if key == :label_events, do: {item.label, item.action, DateTime.to_unix(item.at, :microsecond)}, else: {item.ref, DateTime.to_unix(item.at, :microsecond)} end)
    |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond))
  end
end
