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
    # shortcut: one linear scan per page; add a day index only if C12-T06 measures a bottleneck.
    dated = Enum.map(index.hist, fn row -> {row, midnight(row.end, zone)} end)
    available = dated |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.filter(&(is_nil(before) or &1 < before)) |> Enum.sort(:desc)
    chosen = available |> Enum.take(days) |> MapSet.new()
    rows = for {row, day} <- dated, MapSet.member?(chosen, day), do: row
    from = if index.history_meta.total == nil, do: nil, else: Enum.min(chosen, fn -> before end)
    history = Map.merge(index.history_meta, %{from: from, more: length(available) > days, tz: zone})
    {rows, history}
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
