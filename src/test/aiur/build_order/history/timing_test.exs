defmodule Aiur.BuildOrder.History.TimingTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.{History, Lifecycle}
  alias Aiur.BuildOrder.History.{Row, Timing}
  alias Aiur.TestSupport.BuildHome.FixtureSource
  @t ~U[2026-10-01 10:00:00Z]

  test "unknown start never becomes creation or end, including payload" do
    row = derive(%{created_at: DateTime.add(@t, -86_400), closed_at: @t})
    assert {row.start, row.start_source, row.end} == {:unknown, :unknown, @t}
    assert Timing.to_payload(row) == %{start: nil, end: DateTime.to_unix(@t, :millisecond), start_src: "unknown"}
  end

  test "earliest label wins over an earlier dispatch; running end is none" do
    label = %{label: "agent:in-progress", action: :labeled, at: @t, actor: :unknown}
    row = derive(%{in_progress_at: DateTime.add(@t, 60), dispatched_at: DateTime.add(@t, -60), label_events: [label], closed_at: :none, lifecycle: %Lifecycle{state: :open, state_reason: :none}})
    assert {row.start, row.start_source, row.end} == {@t, :label, :none}
    assert Timing.to_payload(row).end == nil
    row = derive(%{in_progress_at: DateTime.add(@t, -30), label_events: [label]})
    assert row.start == DateTime.add(@t, -30)
  end

  test "dispatch fallback ends at close" do
    start = DateTime.add(@t, -3600)
    row = derive(%{dispatched_at: start, closed_at: @t})
    assert {row.start, row.start_source, row.end} == {start, :dispatch, @t}
  end

  test "future regression guard: zero duration is not padded" do
    row = derive(%{in_progress_at: @t, merged_at: @t})
    assert {row.start, row.end} == {@t, @t}
  end

  test "five minute skew clamps to end, larger skew falls back or stays unknown" do
    for seconds <- [1, 180, 300] do
      row = derive(%{in_progress_at: DateTime.add(@t, seconds), closed_at: @t})
      assert {row.start, row.start_source} == {@t, :label}
    end

    row = derive(%{in_progress_at: DateTime.add(@t, 301), dispatched_at: DateTime.add(@t, -60), closed_at: @t})
    assert {row.start, row.start_source} == {DateTime.add(@t, -60), :dispatch}
    assert derive(%{in_progress_at: DateTime.add(@t, 301), closed_at: @t}).start == :unknown
  end

  test "reopen preserves end, later closes advance it, merge wins and never retreats" do
    first = derive(%{closed_at: @t, in_progress_at: DateTime.add(@t, -60)})
    reopened = Timing.derive(first, %{first | closed_at: :none})
    assert reopened.end == @t
    later = DateTime.add(@t, 86_400)
    closed = Timing.derive(reopened, %{reopened | closed_at: later})
    assert closed.end == later
    replay = Timing.derive(closed, %{closed | closed_at: @t})
    assert replay.end == later
    merged = Timing.derive(replay, %{replay | merged_at: DateTime.add(later, 60)})
    older = Timing.derive(merged, %{merged | merged_at: @t, closed_at: DateTime.add(later, 120)})
    assert older.end == merged.end
    assert older.start == first.start
  end

  test "derivation itself keeps earliest starts and known merge evidence" do
    old = derive(%{in_progress_at: @t, dispatched_at: DateTime.add(@t, -60), merged_at: DateTime.add(@t, 3600)})
    later = Timing.derive(old, %{old | in_progress_at: DateTime.add(@t, 120), dispatched_at: DateTime.add(@t, 180), merged_at: :none})
    assert {later.in_progress_at, later.dispatched_at, later.merged_at} == {old.in_progress_at, old.dispatched_at, old.merged_at}
    assert later.start == old.start
  end

  test "closed without a timestamp has unknown end" do
    row = derive(%{lifecycle: %Lifecycle{state: :closed, state_reason: :unknown}, closed_at: :unknown})
    assert row.end == :unknown
    assert Timing.to_payload(row).end == nil
  end

  test "future regression guard: multi-day bars include pause and rework time" do
    finish = DateTime.add(@t, 28 * 3600)
    row = derive(%{in_progress_at: @t, merged_at: finish})
    assert {row.start, row.end} == {@t, finish}
  end

  test "store merges late signals and replay changes nothing" do
    dir = Aiur.TestSupport.tmp_root!("timing-store")
    on_exit(fn -> File.rm_rf!(dir) end)

    for {name, times} <- [{__MODULE__.Forward, [@t, DateTime.add(@t, -60)]}, {__MODULE__.Reverse, [DateTime.add(@t, -60), @t]}] do
      start_supervised!({History, name: name, repository: "acme/widgets", state_dir: Path.join(dir, inspect(name)), flush_ms: 60_000})
      events = Enum.map(times, &%{number: 1, observed_at: @t, source: :write, fields: %{in_progress_at: &1}})
      assert {:ok, _} = History.apply(events, server: name)
      assert {:ok, [row], _} = History.rows([1], server: name)
      assert row.start == DateTime.add(@t, -60)
      assert {:ok, %{changed: []}} = History.apply(events, server: name)
    end
  end

  test "late close arriving after reopen still supplies the historical end" do
    open = %{number: 1, observed_at: DateTime.add(@t, 60), source: :poll, fields: %{updated_at: DateTime.add(@t, 60), closed_at: :none, lifecycle: %Lifecycle{state: :open, state_reason: :reopened}}}
    {:changed, row} = Row.merge(nil, open)
    closed = %{number: 1, observed_at: @t, source: :backfill, fields: %{updated_at: @t, closed_at: @t}}
    assert {:changed, row} = Row.merge(row, closed)
    assert {row.closed_at, row.end} == {:none, @t}
  end

  test "backfill signal merge honors the configured prefix and ignores unlabels" do
    labels = [
      %{label: "custom:in-progress", action: :labeled, at: @t},
      %{label: "custom:in-progress", action: :unlabeled, at: DateTime.add(@t, -60)},
      %{label: "agent:in-progress", action: :labeled, at: DateTime.add(@t, -120)}
    ]

    assert Timing.merge(%{}, labels, "custom") == %{in_progress_at: @t}
    assert Timing.merge(%{}, :unknown, "custom") == %{}
  end

  test "fixture history timestamps reach integer millisecond payloads unchanged" do
    for dataset <- ~w(live dense) do
      {:ok, data} = FixtureSource.full(dataset: dataset)

      for item <- data["sections"]["hist"] do
        row = derive(%{in_progress_at: DateTime.from_unix!(item["start"], :millisecond), merged_at: DateTime.from_unix!(item["end"], :millisecond)})
        assert Timing.to_payload(row) == %{start: item["start"], end: item["end"], start_src: "label"}
      end
    end
  end

  defp derive(fields), do: Timing.derive(nil, struct!(Row, fields))
end
