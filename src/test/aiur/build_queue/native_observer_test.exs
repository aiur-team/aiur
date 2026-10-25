Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.NativeObserverTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildQueue.{Model.Edge, NativeObserver, Planner, PlannerFixture, Reconcile}
  alias Aiur.Config.Schema

  defmodule Boundary do
    def blocked_by(id) do
      Process.put(:native_reads, [id | Process.get(:native_reads, [])])
      Process.get(:native_result, {:ok, ["3"]})
    end

    def issue_closure(id, _age) do
      Process.put(:closure_reads, [id | Process.get(:closure_reads, [])])
      Process.get(:closure_result, {:ok, %{open?: false, state_reason: "completed"}})
    end

    def ticket_pull_request(id), do: Process.get({:pr, id}, {:ok, nil})
    def status(_ids), do: :unavailable
  end

  setup do
    input = PlannerFixture.input()
    settings = %Schema{build_queue: %Schema.BuildQueue{}, polling: %Schema.Polling{}}
    document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
    state = %{document: document, settings: settings, tracker: Boundary, closure_cache: %{}, clock: fn -> 10_000 end, holds: MapSet.new(), claim_probe: Boundary, reconciles: 0, intent_reconciles: %{}}
    {:ok, input: input, state: state}
  end

  test "native open blocker holds promotion through reconciliation", %{input: input, state: state} do
    observations = Map.put(input.observations, "3", %{PlannerFixture.observation("3") | labels: []})
    {[projection], actions, _, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.state == :waiting
    assert projection.verdict == :waiting
    refute {:promote, "1"} in actions
    assert Process.get(:native_reads) == ["1"]
    assert state.document.edges == []
  end

  test "native prerequisite carries closed-unmerged PR evidence", %{input: input, state: state} do
    Process.put({:pr, "3"}, {:ok, %{state: :closed, merged?: false}})
    observations = Map.put(input.observations, "3", %{PlannerFixture.observation("3") | labels: []})
    {[projection], actions, observations, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.verdict == {:failed, [:pr_closed_unmerged]}
    assert observations["3"].pr == :closed_unmerged
    refute {:promote, "1"} in actions
  end

  test "pending list prerequisite makes no native read", %{input: input, state: state} do
    edge = %Edge{prerequisite: "2", dependent: "1", source: :list}
    state = %{state | document: %{state.document | edges: [edge]}}
    observations = Map.put(input.observations, "2", PlannerFixture.observation("2"))
    {[_], actions, _, _, _, _, _} = Reconcile.plan(state, observations)
    refute {:promote, "1"} in actions
    assert Process.get(:native_reads, []) == []
  end

  test "errors and external edges hold with explicit unknown verdicts", %{input: input, state: state} do
    for {error, cause} <- [{:timeout, :native_dependencies}, {:external_edge, :external_edge}] do
      Process.put(:native_result, {:error, error})
      {[projection], actions, _, _, _, _, _} = Reconcile.plan(state, input.observations)
      assert projection.state == :unknown
      assert projection.verdict == {:unknown, [cause]}
      refute {:promote, "1"} in actions
    end
  end

  test "native edges use closure evidence and reopen invalidates terminal cache", %{input: input, state: state} do
    {enriched, cache} = NativeObserver.observe(input, state, %{})
    assert enriched.edges == [%Edge{prerequisite: "3", dependent: "1", source: :native}]
    assert {[%{state: :ready}], actions} = Planner.plan(enriched)
    assert {:promote, "1"} in actions
    assert Process.get(:closure_reads) == ["3"]
    {_again, cache} = NativeObserver.observe(input, %{state | closure_cache: cache}, cache)
    assert Process.get(:closure_reads) == ["3"]
    input = %{input | observations: Map.put(input.observations, "3", PlannerFixture.observation("3"))}
    {enriched, cache} = NativeObserver.observe(input, state, cache)
    assert cache == %{}
    assert {[%{state: :waiting}], _} = Planner.plan(enriched)
  end

  test "build orders and held items never read native dependencies", %{input: input, state: state} do
    for input <- [%{input | queues: Enum.map(input.queues, &%{&1 | kind: :build_order})}, PlannerFixture.update_item(input, hold: :operator)] do
      {enriched, _} = NativeObserver.observe(input, state, %{})
      assert enriched.edges == []
    end

    assert Process.get(:native_reads, []) == []
  end

  test "unsupported port fails closed", %{input: input, state: state} do
    {enriched, _} = NativeObserver.observe(input, %{state | tracker: __MODULE__}, %{})
    assert {[%{state: :unknown, verdict: {:unknown, [:native_dependencies]}}], actions} = Planner.plan(enriched)
    refute {:promote, "1"} in actions
  end
end
