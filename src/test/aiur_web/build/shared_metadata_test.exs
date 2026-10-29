Code.require_file("../../support/build_home/queue_read_model_fixture.ex", __DIR__)

defmodule AiurWeb.Build.SharedMetadataTest do
  use ExUnit.Case, async: true
  alias Aiur.Projections.UnitsRow
  alias Aiur.TrackerIdentity
  alias AiurWeb.Build.{IndexReader, NowRows, PlannedRows}
  import Aiur.TestSupport.BuildHome.IndexParts
  import Aiur.Test.BuildHome.QueueReadModelFixture, only: [item: 1, item: 2, edge: 2, show: 1]

  test "Units and Now rows retain sourced priority, lane and per-ticket progress freshness" do
    identity = identity()

    snapshot =
      UnitsRow.snapshot(%{
        membership: %{members: [%{identity: identity, lifecycle: :live, terminal?: false}]},
        status: %{running: [%{tracker_identity: identity, priority: 4, labels: ["build-lane:runtime"], work_state: :working}], retrying: [], idle: []},
        issue_facts: %{entries: [%{identity: identity, priority: 2, labels: ["build-lane:platform"]}]},
        activity: %{entries: [%{identity: identity, progress: %{status: :known, percent: 62, freshness: :stale}}]}
      })

    assert {:ok, unit} = UnitsRow.lookup(snapshot, identity)
    assert unit.priority == 2
    assert unit.field_sources.priority == :canonical_issue
    projected = project(unit)
    assert {projected.priority, projected.lane, projected.pct, projected.progress_freshness} == {2, "platform", 62, "stale"}
  end

  test "Now metadata keeps unknown evidence unknown and legacy stale evidence stale" do
    base = %{identity: identity(), runtime: %{bucket: :running, work_state: :working}, reasons: %{}, progress: :unknown}
    unknown = project(base)
    assert {unknown.priority, unknown.lane, unknown.progress_freshness} == {nil, nil, "unknown"}
    stale = project(Map.merge(base, %{progress_percent: 71, progress_freshness: :stale, priority: 3, build_lane: "runtime"}))
    assert {stale.pct, stale.progress_freshness, stale.priority, stale.lane} == {71, "stale", 3, "runtime"}
    invalid = project(Map.merge(base, %{progress: %{status: :known, percent: 101, freshness: :fresh}, priority: "2", build_lane: :unassigned}))
    assert {invalid.pct, invalid.progress_freshness, invalid.priority, invalid.lane} == {nil, "unknown", nil, nil}
  end

  test "indexed rows retain history lane and priority without discarding producer metadata" do
    p = parts([row(1, %{labels: ["priority:2", "build-lane:runtime"]}), row(2)])
    producer = now_row(1) |> Map.merge(%{priority: 1, lane: "platform", progress_freshness: "stale"})
    assert {:ok, index} = assemble(put_in(p, [:now, :rows], %{"1" => producer}))
    assert {index.all["1"].priority, index.all["1"].lane, index.all["1"].progress_freshness} == {1, "platform", "stale"}
    assert {index.all["2"].priority, index.all["2"].lane} == {nil, nil}
    assert {:ok, history} = assemble(p)
    assert {history.all["1"].priority, history.all["1"].lane} == {2, "runtime"}
  end

  test "cold fallback preserves priority lane and stale progress from its one snapshot" do
    status = %{identifier: "1", tracker_identity: identity(), state: :running, work_state: :working, priority: 2, labels: ["build-lane:runtime"]}

    read =
      IndexReader.read(MapSet.new([:now]), parts(),
        units_fun: fn -> %{status: :empty, snapshot: %{rows: []}} end,
        running_rows_fun: fn _ -> {:ok, %{statuses: [status], running: [%{identifier: "1", progress_percent: 62, progress_freshness: :stale}]}} end
      )

    assert {read.now.rows["1"].priority, read.now.rows["1"].lane, read.now.rows["1"].progress_freshness} == {2, "runtime", "stale"}
  end

  test "planned readiness follows prerequisite verdicts while outside-queue todo remains unknown" do
    items = [
      item(1),
      item(2, prerequisites: [edge(1, :satisfied)]),
      item(3, prerequisites: [edge(1, :pending)]),
      item(4, state: :unknown, verdict: :unknown),
      item(6, prerequisites: [edge(1, :unknown)])
    ]

    todo = row(5, %{lifecycle: %Aiur.BuildOrder.Lifecycle{state: :open}, labels: ["agent:todo"]})
    rows = PlannedRows.build(show(items), {:ok, %{rows: %{5 => todo}}}, todo_label: "agent:todo").rows |> Map.new(&{&1.num, &1})
    assert rows[1].dependency_ready == true
    assert rows[2].dependency_ready == true
    assert rows[3].dependency_ready == false
    assert rows[4].dependency_ready == nil
    assert rows[5].dependency_ready == nil
    assert rows[6].dependency_ready == nil
  end

  defp project(row), do: NowRows.build(%{status: :ready, snapshot: %{rows: [row]}}, repository: {"acme", "widgets"}).rows["1"]

  defp identity do
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I_shared_metadata", "number" => 1}, {"acme", "widgets"}, {"acme", "widgets"})
    identity
  end
end
