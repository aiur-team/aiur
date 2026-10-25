defmodule Aiur.BuildOrder.IndexPagesTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index

  test "initial window and earlier pages use active local days across empty calendar days" do
    rows = for {day, n} <- Enum.with_index([1, 2, 4, 6, 7], 1), do: row(n, %{end: DateTime.new!(Date.new!(2026, 10, day), ~T[14:00:00])})
    assert {:ok, index} = assemble(parts(rows))
    initial = Index.window(Index.base(index), "America/Los_Angeles", now())
    assert Enum.map(initial.sections.hist, & &1.num) == [4, 5]
    assert initial.history == %{from: DateTime.to_unix(~U[2026-10-06 07:00:00Z], :millisecond), more: true, total: 5, undated: 0, tz: "America/Los_Angeles"}
    assert {:ok, page} = Index.earlier(index, initial.history.from, "America/Los_Angeles", 3)
    assert Enum.map(page.rows, & &1.num) == [1, 2, 3]
    assert page.history.more == false
    assert page.history.from == DateTime.to_unix(~U[2026-10-01 07:00:00Z], :millisecond)
    for days <- [0, 32, "3"], do: assert(Index.earlier(index, initial.history.from, "Etc/UTC", days) == {:error, :invalid_params})
  end

  test "zone boundaries, unknown zones, DST and midnight gaps preserve each row exactly once" do
    assert {:ok, index} = assemble(parts([row(1, %{end: ~U[2026-10-07 06:30:00Z]})]))
    assert Index.window(Index.base(index), "America/Los_Angeles", now()).history.from == DateTime.to_unix(~U[2026-10-06 07:00:00Z], :millisecond)
    utc = Index.window(Index.base(index), "Mars/Base", now())
    assert utc.history.tz == "Etc/UTC"
    assert utc.history.from == DateTime.to_unix(~U[2026-10-07 00:00:00Z], :millisecond)
    first = Index.local_midnight(~D[2026-11-01], "America/Los_Angeles")
    next = Index.local_midnight(~D[2026-11-02], "America/Los_Angeles")
    assert next - first == 25 * 3_600_000
    assert {:gap, _, after_gap} = DateTime.new(~D[2026-09-06], ~T[00:00:00], "America/Santiago", Tz.TimeZoneDatabase)
    assert Index.local_midnight(~D[2026-09-06], "America/Santiago") == DateTime.to_unix(after_gap, :millisecond)
    rows = [row(1, %{end: ~U[2026-11-01 08:30:00Z]}), row(2, %{end: ~U[2026-11-01 09:30:00Z]}), row(3, %{end: ~U[2026-11-02 08:30:00Z]})]
    assert {:ok, index} = assemble(parts(rows))
    assert Enum.map(Index.window(Index.base(index), "America/Los_Angeles", now()).sections.hist, & &1.num) == [1, 2, 3]
  end

  test "undated closures never enter a day page; empty complete history guard uses zero" do
    assert {:ok, index} = assemble(parts([row(1, %{end: :unknown})]))
    page = Index.window(Index.base(index), "Etc/UTC", now())
    assert page.sections.hist == []
    assert page.history == %{from: nil, more: false, total: 0, undated: 1, tz: "Etc/UTC"}
    assert {:ok, empty} = assemble(parts())
    assert empty.history_meta == %{total: 0, undated: 0}
    assert empty.sources.history.state == "ok"
  end

  test "a non-integer end in hist is skipped, never shown as the newest day" do
    assert {:ok, index} = assemble(parts([row(1, %{end: ~U[2026-10-06 12:00:00Z]}), row(2, %{end: ~U[2026-10-07 12:00:00Z]})]))
    base = Index.base(index)
    [old, new] = base.hist

    for bad <- [nil, :unknown] do
      page = Index.window(%{base | hist: [old, %{new | num: 3, end: bad}, new]}, "Etc/UTC", now())
      assert Enum.map(page.sections.hist, & &1.num) == [1, 2]
    end
  end

  test "day walk matches a per-row reference across zones, DST and off-midnight cursors" do
    start = ~U[2026-10-25 03:00:00Z]
    rows = for n <- 1..400, do: row(n, %{end: DateTime.add(start, n * 4_877)})
    assert {:ok, index} = assemble(parts(rows))

    for zone <- ~w(Etc/UTC America/Los_Angeles Europe/London Asia/Kolkata),
        before <- [nil | Enum.map([3, 99, 250, 401], &DateTime.to_unix(DateTime.add(start, &1 * 4_877), :millisecond))],
        days <- [1, 2, 5] do
      {rows, history} = if before, do: earlier!(index, before, zone, days), else: first!(index, zone)
      {expected, from, more} = reference(index.hist, before, zone, if(before, do: days, else: 2))
      assert {Enum.map(rows, & &1.num), history.from, history.more} == {Enum.map(expected, & &1.num), from, more}
    end
  end

  defp first!(index, zone) do
    page = Index.window(Index.base(index), zone, now())
    {page.sections.hist, page.history}
  end

  defp earlier!(index, before, zone, days) do
    {:ok, page} = Index.earlier(index, before, zone, days)
    {page.rows, page.history}
  end

  # The pre-walk implementation: resolve every row's local midnight, then pick days.
  defp reference(hist, before, zone, days) do
    dated = Enum.map(hist, fn row -> {row, row.end |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone!(zone, Tz.TimeZoneDatabase) |> DateTime.to_date() |> Index.local_midnight(zone)} end)
    available = dated |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.filter(&(is_nil(before) or &1 < before)) |> Enum.sort(:desc)
    chosen = available |> Enum.take(days) |> MapSet.new()
    {for({row, day} <- dated, MapSet.member?(chosen, day), do: row), Enum.min(chosen, fn -> before end), length(available) > days}
  end
end
