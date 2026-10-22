defmodule Aiur.BuildOrder.Index.Pages do
  @moduledoc false
  @blocks ~w(epics features order counts sources repo)a

  @spec base(map()) :: map()
  def base(index) do
    sections = Map.new(~w(now plan nq)a, fn sec -> {sec, index.all |> Map.values() |> Enum.filter(&(&1.sec == Atom.to_string(sec))) |> Enum.sort_by(&{&1.ord, &1.id})} end)
    index |> Map.take(@blocks ++ [:hist, :history_meta]) |> Map.put(:sections, sections)
  end

  @spec window(map(), String.t(), integer()) :: map()
  def window(base, zone, now) do
    {rows, history} = page(base, nil, zone, 2)
    base |> Map.take(@blocks) |> Map.merge(%{now: now, sections: Map.put(base.sections, :hist, rows), history: history})
  end

  @spec earlier(map(), integer(), String.t(), integer()) :: {:ok, map()} | {:error, :invalid_params}
  def earlier(index, before, zone, days) when is_integer(before) and before > 0 and is_integer(days) and days in 1..31 do
    {rows, history} = page(index, before, zone, days)
    {:ok, %{rows: rows, history: history}}
  end

  def earlier(_index, _before, _zone, _days), do: {:error, :invalid_params}

  @spec local_midnight(Date.t(), String.t()) :: integer()
  def local_midnight(date, zone) do
    time =
      case DateTime.new(date, ~T[00:00:00], zone, Tz.TimeZoneDatabase) do
        {:ok, time} -> time
        {:ambiguous, first, _} -> first
        {:gap, _, after_gap} -> after_gap
      end

    DateTime.to_unix(time, :millisecond)
  end

  defp page(index, before, zone, days) do
    zone = zone(zone)
    {rows, chosen, more} = walk(Enum.reverse(index.hist), before, zone, days, nil, [], [])
    from = if index.history_meta.total == nil, do: nil, else: Enum.min(chosen, fn -> before end)
    history = Map.merge(index.history_meta, %{from: from, more: more, tz: zone})
    {rows, history}
  end

  # Rows arrive newest first; resolve one local midnight per day crossed, not per row.
  # Prepending restores ascending order; `chosen` holds the oldest chosen midnight at its head.
  defp walk([], _before, _zone, _days, _day, rows, chosen), do: {rows, chosen, false}
  # Atoms sort above integers, so a non-integer end would land on the newest day; skip it.
  defp walk([row | rest], before, zone, days, day, rows, chosen) when not is_integer(row.end), do: walk(rest, before, zone, days, day, rows, chosen)

  defp walk([row | rest], before, zone, days, day, rows, chosen) when is_integer(day) and row.end >= day do
    rows = if match?([^day | _], chosen), do: [row | rows], else: rows
    walk(rest, before, zone, days, day, rows, chosen)
  end

  defp walk([row | rest], before, zone, days, _day, rows, chosen) do
    day = midnight(row.end, zone)

    cond do
      is_integer(before) and day >= before -> walk(rest, before, zone, days, day, rows, chosen)
      length(chosen) == days -> {rows, chosen, true}
      true -> walk(rest, before, zone, days, day, [row | rows], [day | chosen])
    end
  end

  defp midnight(ms, zone) do
    ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(zone, Tz.TimeZoneDatabase) |> DateTime.to_date() |> local_midnight(zone)
  end

  defp zone(zone) when is_binary(zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone, Tz.TimeZoneDatabase) do
      {:ok, _} -> zone
      _ -> "Etc/UTC"
    end
  end

  defp zone(_), do: "Etc/UTC"
end
