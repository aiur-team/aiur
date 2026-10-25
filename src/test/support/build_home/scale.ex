defmodule Aiur.TestSupport.BuildHome.Scale do
  @moduledoc """
  Deterministic large build-home datasets derived from a v1 fixture map.

  History is the base history replicated back in time by whole local weeks, so
  per-day density, weekday shape and edges stay those of the design data. No
  RNG and no clock: the same input always gives the same map.
  """

  @offset 100_000
  @zone "America/Los_Angeles"

  @doc "The base map with history copies appended until it holds exactly `n` rows."
  @spec dataset(map(), pos_integer()) :: map()
  def dataset(base, n) do
    hist = base["sections"]["hist"]
    ids = MapSet.new(hist, & &1["id"])
    if Enum.any?(all_rows(base), &(String.to_integer(&1["id"]) >= @offset)), do: raise(ArgumentError, "base ids must stay below #{@offset}")
    missing = n - length(all_rows(base))
    if missing < 0, do: raise(ArgumentError, "base already holds more than #{n} rows")
    shift = shift_days(hist)
    newest_first = Enum.sort_by(hist, &{-&1["end"], &1["id"]})

    copies =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.flat_map(fn k -> Enum.map(newest_first, &copy(&1, k, k * shift, ids)) end)
      |> Enum.take(missing)

    base
    |> put_in(["sections", "hist"], hist ++ prune(copies))
    |> refresh()
  end

  # The last copy is partial: its oldest rows are cut, so drop links to copy ids that were not generated.
  defp prune(copies) do
    present = MapSet.new(copies, & &1["id"])
    keep? = fn id -> String.to_integer(id) < @offset or MapSet.member?(present, id) end

    Enum.map(copies, fn row ->
      Map.merge(row, %{
        "deps" => Enum.filter(row["deps"], keep?),
        "children" => Enum.filter(row["children"], keep?),
        "dep_states" => Map.filter(row["dep_states"], fn {id, _} -> keep?.(id) end)
      })
    end)
  end

  @doc "The base map whose not-queued section holds `m` copies of the base not-queued rows."
  @spec with_nq(map(), pos_integer()) :: map()
  def with_nq(base, m) do
    nq = base["sections"]["nq"]
    ids = MapSet.new(nq, & &1["id"])
    rows = for i <- 0..(m - 1), do: copy(Enum.at(nq, rem(i, length(nq))), div(i, length(nq)), 0, ids)
    base |> put_in(["sections", "nq"], rows) |> refresh()
  end

  @doc "Marks the first `m` now rows active, copying now rows when fewer exist."
  @spec with_active(map(), pos_integer()) :: map()
  def with_active(base, m) do
    now = base["sections"]["now"]
    extra = for i <- 0..(m - length(now) - 1)//1, do: renumber(Enum.at(now, rem(i, length(now))), 9 * @offset + i)

    rows =
      (now ++ extra)
      |> Enum.with_index()
      |> Enum.map(fn {row, i} -> if i < m, do: Map.put(row, "agent", Map.put(row["agent"] || agent(), "state", "active")), else: row end)

    base |> put_in(["sections", "now"], rows) |> refresh()
  end

  @doc "The first now row of the base: visible on first paint, so its modal is reachable."
  @spec perf_ticket_id(map()) :: String.t()
  def perf_ticket_id(base), do: hd(base["sections"]["now"])["id"]

  @doc "`n` conversation entries repeating `items`, each repeat one minute older."
  @spec conversation([map()], pos_integer()) :: [map()]
  def conversation(items, n) do
    count = length(items)
    repeats = ceil(n / count)

    for i <- 0..(n - 1) do
      older = repeats - 1 - div(i, count)
      item = Enum.at(items, rem(i, count))
      item |> Map.put("id", "s:#{i}") |> Map.update("at", nil, &(&1 && &1 - older * 60_000))
    end
  end

  @doc "Calendar days from the first to the last history day, in the fixture zone."
  @spec span_days([map()]) :: pos_integer()
  def span_days(hist) do
    days = Enum.map(hist, &local_date(&1["end"]))
    Date.diff(Enum.max(days, Date), Enum.min(days, Date)) + 1
  end

  @doc "Whole weeks covering the base history, so a copy keeps every row's weekday."
  @spec shift_days([map()]) :: pos_integer()
  def shift_days(hist), do: 7 * ceil(span_days(hist) / 7)

  @doc "Moves a millisecond time back `days` local calendar days, keeping the local wall time."
  @spec shift_local(integer() | nil, non_neg_integer()) :: integer() | nil
  def shift_local(nil, _days), do: nil

  def shift_local(ms, days) do
    local = ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(@zone, Tz.TimeZoneDatabase)

    case DateTime.new(Date.add(DateTime.to_date(local), -days), DateTime.to_time(local), @zone, Tz.TimeZoneDatabase) do
      {:ok, time} -> DateTime.to_unix(time, :millisecond)
      {:ambiguous, first, _second} -> DateTime.to_unix(first, :millisecond)
      {:gap, _before, later} -> DateTime.to_unix(later, :millisecond)
    end
  end

  @spec local_date(integer()) :: Date.t()
  def local_date(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(@zone, Tz.TimeZoneDatabase) |> DateTime.to_date()

  defp copy(row, 0, _days, _ids), do: row

  defp copy(row, k, days, ids) do
    remap = fn id -> if MapSet.member?(ids, id), do: shift_id(id, k), else: id end

    row
    |> renumber(String.to_integer(row["id"]) + k * @offset)
    |> Map.merge(%{
      "start" => shift_local(row["start"], days),
      "end" => shift_local(row["end"], days),
      "created" => shift_local(row["created"], days),
      "deps" => Enum.map(row["deps"], remap),
      "children" => Enum.map(row["children"], remap),
      "dep_states" => Map.new(row["dep_states"], fn {id, state} -> {remap.(id), state} end)
    })
  end

  defp renumber(row, num), do: Map.merge(row, %{"id" => Integer.to_string(num), "num" => num})
  defp shift_id(id, k), do: Integer.to_string(String.to_integer(id) + k * @offset)
  defp agent, do: %{"model" => "claude", "state" => nil, "effort" => "high", "name" => "Claude"}
  defp all_rows(data), do: data["sections"] |> Map.values() |> List.flatten()

  defp refresh(data) do
    counts = Enum.reduce(all_rows(data), Map.new(data["order"], &{&1, 0}), fn row, acc -> Map.update(acc, row["epic"] || "unsorted", 1, &(&1 + 1)) end)
    data |> Map.put("counts", counts) |> put_in(["history", "total"], length(data["sections"]["hist"]))
  end
end
