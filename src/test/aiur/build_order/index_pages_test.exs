defmodule Aiur.BuildOrder.IndexPagesTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.Index

  test "initial window and earlier pages use active local days across empty calendar days" do
    rows = for {day, n} <- Enum.with_index([1, 2, 4, 6, 7], 1), do: row(n, %{end: DateTime.new!(Date.new!(2026, 10, day), ~T[14:00:00])})
    assert {:ok, index} = assemble(parts(rows))
    initial = Index.window(index, "America/Los_Angeles", now())
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
    assert Index.window(index, "America/Los_Angeles", now()).history.from == DateTime.to_unix(~U[2026-10-06 07:00:00Z], :millisecond)
    utc = Index.window(index, "Mars/Base", now())
    assert utc.history.tz == "Etc/UTC"
    assert utc.history.from == DateTime.to_unix(~U[2026-10-07 00:00:00Z], :millisecond)
    first = Index.local_midnight(~D[2026-11-01], "America/Los_Angeles")
    next = Index.local_midnight(~D[2026-11-02], "America/Los_Angeles")
    assert next - first == 25 * 3_600_000
    assert {:gap, _, after_gap} = DateTime.new(~D[2026-09-06], ~T[00:00:00], "America/Santiago", Tz.TimeZoneDatabase)
    assert Index.local_midnight(~D[2026-09-06], "America/Santiago") == DateTime.to_unix(after_gap, :millisecond)
    rows = [row(1, %{end: ~U[2026-11-01 08:30:00Z]}), row(2, %{end: ~U[2026-11-01 09:30:00Z]}), row(3, %{end: ~U[2026-11-02 08:30:00Z]})]
    assert {:ok, index} = assemble(parts(rows))
    assert Enum.map(Index.window(index, "America/Los_Angeles", now()).sections.hist, & &1.num) == [1, 2, 3]
  end

  test "undated closures never enter a day page; empty complete history guard uses zero" do
    assert {:ok, index} = assemble(parts([row(1, %{end: :unknown})]))
    page = Index.window(index, "Etc/UTC", now())
    assert page.sections.hist == []
    assert page.history == %{from: nil, more: false, total: 0, undated: 1, tz: "Etc/UTC"}
    assert {:ok, empty} = assemble(parts())
    assert empty.history_meta == %{total: 0, undated: 0}
    assert empty.sources.history.state == "ok"
  end
end
