Code.require_file("../../support/build_queue_planner_fixture.exs", __DIR__)

defmodule Aiur.BuildQueue.StartTriggerProgressTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildQueue.{Model.Edge, PlannerFixture, PRObserver, Reconcile}
  alias Aiur.Config.Schema
  alias Aiur.StartTrigger.ProgressStore

  defmodule Boundary do
    def blocked_by(_id), do: {:ok, Process.get(:progress_native_ids, [])}
    def status(_ids), do: :unavailable
  end

  setup do
    if is_nil(Process.whereis(ProgressStore)), do: start_supervised!(ProgressStore)
    id = "queue-progress-#{System.unique_integer([:positive])}"
    input = PlannerFixture.input()
    settings = %Schema{build_queue: %Schema.BuildQueue{start_trigger: "pr_ci_green"}, polling: %Schema.Polling{}}
    document = input |> Map.from_struct() |> Map.take([:queues, :items, :edges, :intents, :latches])
    document = %{document | edges: [%Edge{prerequisite: id, dependent: "1", source: :list}]}
    state = %{document: document, settings: settings, tracker: Boundary, clock: fn -> 10_000 end, holds: MapSet.new(), claim_probe: Boundary, reconciles: 0, intent_reconciles: %{}}
    observations = Map.put(input.observations, id, %{PlannerFixture.observation(id) | labels: ["agent:in-progress"]})
    {:ok, state: state, observations: observations, id: id}
  end

  test "CI progress readies an in-progress prerequisite without a tracker PR port", %{state: state, observations: observations, id: id} do
    record(id, %{pr_number: 17, stage: :pr_ci_green})
    {[projection], actions, observations, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.state == :ready
    assert observations[id].stage_reached == :pr_ci_green
    assert {:promote, "1"} in actions
  end

  test "unbound boot progress does not release a replacement PR", %{state: state, observations: observations, id: id} do
    record(id, %{pr_number: nil, stage: :pr_ci_green, head_sha: "old-head", source: :boot})
    {[projection], actions, _, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.verdict == :waiting
    refute {:promote, "1"} in actions
  end

  test "stored merge sets the PR marker and starts the merged-open grace clock", %{state: state, observations: observations, id: id} do
    record(id, %{pr_number: 17, stage: :pr_merged})
    {observations, _} = PRObserver.observe(observations, state)
    assert observations[id].pr == :merged
    assert observations[id].merged_at_ms == state.clock.()
  end

  test "closed-unmerged progress overrides a previously reached stage", %{state: state, observations: observations, id: id} do
    record(id, %{pr_number: 17, stage: :pr_ci_green})
    record(id, %{pr_number: 17, closed_unmerged?: true})
    {[projection], actions, observations, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.verdict == {:failed, [:pr_closed_unmerged]}
    assert observations[id].pr == :closed_unmerged
    refute {:promote, "1"} in actions
  end

  test "a missing row clears transient progress and keeps the prerequisite pending", %{state: state, observations: observations, id: id} do
    observations = Map.update!(observations, id, &%{&1 | stage_reached: :pr_ci_green})
    {[projection], actions, observations, _, _, _, _} = Reconcile.plan(state, observations)
    assert projection.verdict == :waiting
    assert observations[id].stage_reached == nil
    refute {:promote, "1"} in actions
  end

  test "a new PR resets progress copied by consecutive observer passes", %{state: state, observations: observations, id: id} do
    record(id, %{pr_number: 17, stage: :pr_ci_green})
    {observations, _} = PRObserver.observe(observations, state)
    assert observations[id].stage_reached == :pr_ci_green
    record(id, %{pr_number: 18, stage: :pr_opened})
    {observations, _} = PRObserver.observe(observations, state)
    assert observations[id].stage_reached == :pr_opened
  end

  test "only approval-trigger prerequisites are watched, including native edges", %{state: state, observations: observations, id: id} do
    queue = %{hd(state.document.queues) | start_trigger: :pr_approved}
    ci_queue = %{queue | id: "ci", name: "ci", start_trigger: :pr_ci_green}
    ci_id = id <> "-ci"
    native_id = id <> "-native"
    member = %{PlannerFixture.item("4") | queue_id: "ci"}
    ci_edge = %Edge{prerequisite: ci_id, dependent: "4", source: :list}
    document = %{state.document | queues: [queue, ci_queue], items: state.document.items ++ [member], edges: state.document.edges ++ [ci_edge]}
    observations = observations |> Map.put(ci_id, PlannerFixture.observation(ci_id)) |> Map.put("4", PlannerFixture.observation("4"))
    Reconcile.plan(%{state | document: document}, observations)
    assert Map.has_key?(:sys.get_state(ProgressStore).watches, id)
    refute Map.has_key?(:sys.get_state(ProgressStore).watches, ci_id)

    Process.put(:progress_native_ids, [native_id])
    document = %{document | edges: [], items: [hd(state.document.items)], queues: [queue]}
    observations = Map.put(observations, native_id, PlannerFixture.observation(native_id))
    {_, _, _, _, _, _, edges} = Reconcile.plan(%{state | document: document}, observations)
    assert %Edge{prerequisite: native_id, dependent: "1", source: :native} in edges
    assert Map.has_key?(:sys.get_state(ProgressStore).watches, native_id)
  end

  defp record(id, attrs) do
    ProgressStore.record(id, attrs)
    :sys.get_state(ProgressStore)
  end
end
