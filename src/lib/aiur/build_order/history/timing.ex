defmodule Aiur.BuildOrder.History.Timing do
  @moduledoc "Derives honest Gantt intervals from journaled history facts."
  alias Aiur.BuildOrder.History.Row

  # ponytail: fixed five-minute clock tolerance; revisit if the feed measures larger skew.
  @skew_ms 300_000

  @spec derive(Row.t() | nil, Row.t()) :: Row.t()
  def derive(old, new) do
    old = old || %Row{}

    row =
      new
      |> Map.put(:in_progress_at, earliest([old.in_progress_at, new.in_progress_at]))
      |> Map.put(:dispatched_at, earliest([old.dispatched_at, new.dispatched_at]))
      |> Map.put(:merged_at, latest([old.merged_at, new.merged_at]))
      |> Map.put(:last_closed_at, latest([old.last_closed_at, old.closed_at, new.last_closed_at, new.closed_at]))

    end_at = pick_end(row)
    label = earliest([row.in_progress_at, label_time(row.label_events, nil)])
    {start, source} = Enum.find_value([{label, :label}, {row.dispatched_at, :dispatch}], {:unknown, :unknown}, &valid_start(&1, end_at))
    %{row | start: start, start_source: source, end: end_at}
  end

  @spec merge(map(), list() | :unknown, String.t()) :: map()
  def merge(fields, labels, prefix) do
    case label_time(labels, prefix) do
      %DateTime{} = at -> Map.put(fields, :in_progress_at, earliest([Map.get(fields, :in_progress_at, :unknown), at]))
      _unknown -> fields
    end
  end

  @spec to_payload(Row.t()) :: map()
  def to_payload(row) do
    %{start: milliseconds(row.start), end: milliseconds(row.end), start_src: if(match?(%DateTime{}, row.start), do: Atom.to_string(row.start_source), else: "unknown")}
  end

  defp pick_end(%{merged_at: %DateTime{} = at}), do: at
  defp pick_end(%{last_closed_at: %DateTime{} = at}), do: at
  defp pick_end(%{closed_at: :none, lifecycle: %{state: state}}) when state != :closed, do: :none
  defp pick_end(%{lifecycle: %{state: :open}}), do: :none
  defp pick_end(_row), do: :unknown

  defp valid_start({%DateTime{} = at, source}, %DateTime{} = end_at) do
    delta = DateTime.diff(at, end_at, :millisecond)

    cond do
      delta <= 0 -> {at, source}
      delta <= @skew_ms -> {end_at, source}
      true -> nil
    end
  end

  defp valid_start({%DateTime{} = at, source}, _end), do: {at, source}
  defp valid_start(_candidate, _end), do: nil
  defp label_time(:unknown, _prefix), do: :unknown
  defp label_time(events, prefix), do: earliest(for %{label: label, action: :labeled, at: at} <- events, in_progress_label?(label, prefix), do: at)
  defp in_progress_label?(label, nil), do: String.ends_with?(label, ":in-progress")
  defp in_progress_label?(label, prefix), do: label == prefix <> ":in-progress"
  defp earliest(values), do: extreme(values, :lt)
  defp latest(values), do: extreme(values, :gt)

  defp extreme(values, direction) do
    Enum.reduce(values, :unknown, fn
      %DateTime{} = at, %DateTime{} = old -> if DateTime.compare(at, old) == direction, do: at, else: old
      %DateTime{} = at, _old -> at
      _value, %DateTime{} = old -> old
      :none, _old -> :none
      _value, old -> old
    end)
  end

  defp milliseconds(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp milliseconds(_unknown), do: nil
end
