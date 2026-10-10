Code.require_file("../../support/build_home/queue_read_model_fixture.ex", __DIR__)

defmodule AiurWeb.Build.PlannedRowsTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Build.PlannedRows
  import Aiur.Test.BuildHome.QueueReadModelFixture
  @history {:ok, %{rows: %{}}}

  defmodule Queue do
    alias Aiur.Test.BuildHome.QueueReadModelFixture, as: Fixture
    def show, do: Fixture.show([Fixture.item(1)])
  end

  defmodule Crashed do
    def show, do: exit({:timeout, :queue})
    def snapshot(_opts), do: exit(:history_down)
  end

  defmodule Raised do
    def show, do: raise("queue down")
    def snapshot(_opts), do: raise("snapshot must not be called")
  end

  test "queue order, state selection, dedupe and closed filtering" do
    items = for {state, n} <- Enum.with_index([:claimed, :completed, :cancelled, :removed, :waiting, :ready, :overridden], 1), do: item(n, state: state)
    items = [item(90, rank: 100, position: nil), item(80, rank: 0, position: 40) | items]
    history = {:ok, %{rows: %{6 => %{lifecycle: %{state: :closed}}}}}
    result = PlannedRows.build(show([], queues: [queue(items), queue([item(90), item(10)])]), history, [])
    assert Enum.map(result.rows, &{&1.num, &1.ord, &1.qpos}) == [{90, 0, 1}, {80, 1, 2}, {5, 2, 3}, {7, 3, 4}, {10, 4, 5}]
    assert Enum.all?(result.rows, &(&1.id == to_string(&1.num) and &1.sec == "plan" and &1.status == "queued"))
  end

  test "sources distinguish empty, disabled, unavailable, stale and unknown" do
    assert PlannedRows.build(show([]), @history, []) == %{rows: [], source: %{state: "ok", observed_at: 1_791_417_600_000, reason: nil}}

    for {status, state} <- [disabled: "disabled", unsupported_tracker: "disabled", store_unavailable: "unavailable"] do
      assert PlannedRows.build(show([item(1)], status: status), @history, []) == %{rows: [], source: %{state: state, observed_at: nil, reason: to_string(status)}}
    end

    sources = %{a: %{freshness: :current, observed_at: ~U[2026-10-08 00:00:00Z], reasons: []}, b: %{freshness: :stale, observed_at: ~U[2026-10-07 00:00:00Z], reasons: [:too_old]}}
    assert PlannedRows.build(show([], sources: sources), @history, []).source == %{state: "stale", observed_at: 1_791_331_200_000, reason: "too_old"}
    assert PlannedRows.build(show([], sources: sources, status: :writes_paused), @history, []).source.reason == "writes_paused"
    assert PlannedRows.build(show([], sources: %{a: %{freshness: :unknown, observed_at: nil}}), @history, []).source == %{state: "stale", observed_at: nil, reason: "observation_unknown"}
  end

  test "read failures preserve distinct source states and History crashes preserve rows" do
    for module <- [Crashed, Raised] do
      assert PlannedRows.read(queue: module, history_snapshot: @history) == %{rows: [], source: %{state: "unavailable", observed_at: nil, reason: "read_failed"}}
    end

    assert PlannedRows.read(queue: NotInstalled, history_snapshot: @history).source == %{state: "disabled", observed_at: nil, reason: "not_installed"}
    assert [%{num: 1}] = PlannedRows.read(queue: Queue, history: Crashed).rows
    assert [%{num: 1}] = PlannedRows.read(queue: Queue, history: Raised).rows
    closed = {:ok, %{rows: %{1 => %{lifecycle: %{state: :closed}}}}}
    assert [] == PlannedRows.read(queue: Queue, history: Raised, history_snapshot: closed).rows
    assert [%{num: 1}] = PlannedRows.build(show([item(1)]), {:error, :unavailable}, []).rows
  end

  test "waves include planned, running, satisfied and unknown prerequisites" do
    items = [
      item(1),
      item(2, prerequisites: [edge(1)]),
      item(3, prerequisites: [edge(2)]),
      item(4, prerequisites: [edge(20)]),
      item(5, prerequisites: [edge(30, :satisfied)]),
      item(6, state: :unknown, verdict: :unknown, prerequisites: [edge(40, :unknown)]),
      item(7, state: :unknown),
      item(8, state: :ready, verdict: :unknown)
    ]

    rows = PlannedRows.build(show(items), @history, active: MapSet.new([20])).rows
    assert Enum.map(rows, & &1.wave) == [1, 2, 3, 2, 1, 2, 1, 1]
    assert Enum.at(rows, 3).cue.wait == 20
    assert Enum.at(rows, 5).cue.unknown and Enum.at(rows, 5).cue.waitAny
    assert Enum.at(rows, 6).cue.unknown and not Enum.at(rows, 6).cue.waitAny
    assert Enum.at(rows, 7).cue.unknown and not Enum.at(rows, 7).cue.waitAny
    assert Enum.at(rows, 4).deps == ["30"]
  end

  test "wait names only first pending active prerequisite" do
    items = [item(1, prerequisites: [edge(11), edge(12), edge(13)])]
    assert hd(PlannedRows.build(show(items), @history, active: MapSet.new([12, 13])).rows).cue.wait == 12
    assert hd(PlannedRows.build(show(items), @history, []).rows).cue.wait == nil
    assert hd(PlannedRows.build(show(items), @history, []).rows).cue.waitAny
  end

  test "failed blocks include direct, claimed and transitive dependents and suppress wait" do
    items = [
      item(2, prerequisites: [edge(1, :failed), edge(20)]),
      item(3, prerequisites: [edge(1, :failed)]),
      item(5, state: :claimed, prerequisites: [edge(1, :failed)]),
      item(4, prerequisites: [edge(2)]),
      item(6, prerequisites: [edge(4)])
    ]

    [a, b, c, d] = PlannedRows.build(show(items), @history, active: MapSet.new([20])).rows
    assert a.cue.failed == %{by: 1, blocks: [2, 3, 5, 4, 6]}
    assert b.cue.failed == a.cue.failed
    assert a.cue.wait == nil
    refute a.cue.blockedChain
    assert c.cue.failed == nil and c.cue.blockedChain
    assert d.cue.blockedChain
  end

  test "cycles terminate with deterministic path fallback" do
    rows = PlannedRows.build(show([item(1, prerequisites: [edge(2)]), item(2, prerequisites: [edge(1)])]), @history, []).rows
    assert Enum.map(rows, & &1.wave) == [3, 2]
  end

  test "10,000 item chain has no cap" do
    items = [item(1) | for(n <- 2..10_000, do: item(n, prerequisites: [edge(n - 1)]))]
    {elapsed, result} = :timer.tc(fn -> PlannedRows.build(show(items), @history, []) end)
    IO.puts("planned 10,000-chain: #{elapsed} microseconds")
    assert length(result.rows) == 10_000
    assert List.last(result.rows).wave == 10_000
  end

  test "holds preserve raw facts and queue holds spare promoted and overridden items" do
    items = [
      item(1, state: :held),
      item(2, state: :held, hold_by: "Maya"),
      item(3, state: :held, hold_reason: "freeze"),
      item(4, state: :held, hold_by: "Maya", hold_reason: "\" <freeze>"),
      item(5, state: :promoted_unauthorized)
    ]

    assert Enum.map(PlannedRows.build(show(items), @history, []).rows, & &1.cue.held) == [
             "Held · no actor or reason recorded",
             "Held by Maya",
             "Held · freeze",
             "Held by Maya · \" <freeze>",
             "Held · dispatch not authorized"
           ]

    items = [item(1), item(2, state: :ready), item(3, state: :held), item(4, state: :promoted), item(5, state: :overridden)]
    rows = PlannedRows.build(show([], queues: [queue(items, held: true, name: nil)]), @history, []).rows
    assert Enum.map(rows, & &1.cue.held) == ["Held · queue list:test is held", "Held · queue list:test is held", "Held · queue list:test is held", nil, nil]
  end

  test "promotion time is known or nil" do
    items = [item(1, state: :promoted, promoted_at: ~U[2026-10-08 00:00:00Z]), item(2, state: :promoted)]
    assert Enum.map(PlannedRows.build(show(items), @history, []).rows, & &1.cue.promoted) == [1_791_417_600_000, nil]
  end

  test "outside-queue todo rows follow queue, exclude active and unknown labels, and sort unknown dates last" do
    history =
      {:ok,
       %{
         rows:
           Map.new(
             [
               {300, ~U[2026-10-08 00:00:00Z], ["agent:todo"]},
               {301, :unknown, []},
               {400, ~U[2026-10-07 00:00:00Z], ["agent:todo"]},
               {401, :unknown, :unknown},
               {402, :unknown, ["agent:todo"]},
               {403, :unknown, ["agent:todo"]}
             ],
             fn {n, at, labels} -> {n, %{number: n, lifecycle: %{state: :open}, created_at: at, labels: labels}} end
           )
       }}

    input = show([item(1), item(400, state: :removed)])
    rows = PlannedRows.build(input, history, todo_label: "agent:todo", active: MapSet.new([403])).rows
    assert Enum.map(rows, &{&1.num, &1.ord, &1.qpos, &1.wave}) == [{1, 0, 1, 1}, {400, 1, nil, 1}, {300, 2, nil, 1}, {402, 3, nil, 1}]
    assert Enum.all?(tl(rows), &(&1.deps == [] and &1.cue.waitAny == false and &1.cue.unknown == false))
    assert [%{num: 1}] = PlannedRows.build(input, history, []).rows
    assert Enum.map(PlannedRows.build(%{input | status: :disabled}, history, todo_label: "agent:todo", active: MapSet.new([403])).rows, & &1.num) == [400, 300, 402]
  end

  test "design plan cues round-trip with explicit computed-wave exceptions" do
    {input, fixture, active} = live()
    rows = PlannedRows.build(input, @history, active: active).rows
    assert length(rows) == length(fixture["sections"]["plan"])
    pairs = Enum.zip(rows, fixture["sections"]["plan"])

    for {row, design} <- pairs do
      assert row.num == design["num"] and row.qpos == design["qpos"]
      assert row.deps == Enum.map(design["deps"], &String.replace_prefix(&1, "AIUR-", ""))
      assert row.cue.held == design["cue"]["held"]
      assert row.cue.wait == design["cue"]["wait"]
      assert row.cue.waitAny == design["cue"]["waitAny"]
      assert row.cue.promoted == design["cue"]["promoted"]
    end

    exceptions = for {row, design} <- pairs, row.wave != design["wave"], do: {design["num"], design["title"]}
    assert {620, "Empty page illustrations"} in exceptions
    assert {639, "Release notes 0.9"} in exceptions
    # Generated x<w>_<j> rows are sorted into the design's hand-assigned waves.
    generated = MapSet.new([612, 613, 614, 621, 622, 623, 624, 630, 631, 632, 633, 634, 635, 640, 641, 642, 643, 644] ++ Enum.to_list(645..660))
    assert Enum.all?(exceptions, fn {number, _title} -> number in [620, 639] or MapSet.member?(generated, number) end)
  end
end
