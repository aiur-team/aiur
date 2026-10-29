defmodule Aiur.IdleBurstWorkTest do
  use Aiur.TestSupport

  import Aiur.CurrentRunProjectionsSupport, only: [start_owner: 0]

  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunProjections.CheckpointPersistence
  alias Aiur.GitHub.Transport
  alias Aiur.Issue
  alias Aiur.Orchestrator.DispatchPolicy.IssueStates
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport.AgentStatuses
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload

  test "status construction resolves terminal states once for fifty idle rows" do
    assert_batched_terminal_states(&AgentStatuses.agent_statuses/1)
  end

  test "snapshot construction resolves terminal states a bounded three times for fifty idle rows" do
    # Two fixed capacity-demand calculations plus one for the entire idle bucket.
    assert_batched_terminal_states(&SnapshotPayload.snapshot_payload/1, 3)
  end

  defp assert_batched_terminal_states(build, expected \\ 1) do
    issues = Map.new(1..50, fn n -> {"#{n}", %Issue{id: "#{n}", identifier: "#{n}", state: "todo"}} end)
    state = %State{last_polled_issues: issues, candidate_snapshot_fresh?: true}
    {result, calls} = measured_calls({IssueStates, :terminal_state_set, 0}, fn -> build.(state) end)
    rows = if is_map(result), do: result.idle, else: result
    assert length(rows) == 50
    assert calls == expected
  end

  test "parse_repo reads no whole environment even on repeated calls" do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")
    {repos, calls} = measured_calls({System, :get_env, 0}, fn -> for _ <- 1..3, do: Transport.parse_repo() end)
    assert repos == List.duplicate({:ok, {"owner", "repo"}}, 3)
    assert calls == 0
  end

  test "unchanged checkpoint comparisons and refreshes do not hash; changed checkpoints hash once" do
    {source, owner, _pubsub} = start_owner()
    assert :ok = CurrentRunProjections.refresh(owner)

    {unchanged?, calls} =
      measured_calls({CheckpointPersistence, :content_hash, 1}, fn ->
        state = :sys.get_state(owner)
        CheckpointPersistence.unchanged?(state, state)
      end)

    assert unchanged?
    assert calls == 0

    {result, calls} = measured_calls({CheckpointPersistence, :content_hash, 1}, fn -> CurrentRunProjections.refresh(owner) end, owner)
    assert result == :ok
    assert calls == 0

    {_, calls} =
      measured_calls(
        {CheckpointPersistence, :content_hash, 1},
        fn ->
          Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 7_201_000))
          assert :ok = CurrentRunProjections.refresh(owner)
        end,
        owner
      )

    assert calls == 1
    assert :sys.get_state(owner).summary_snapshot.run.elapsed_wall_ms == 7_201_000
  end

  defp measured_calls(mfa, fun, target \\ nil) do
    parent = self()

    worker =
      spawn_link(fn ->
        receive do: (:run -> send(parent, {:result, self(), fun.()}))
        receive do: (:stop -> :ok)
      end)

    traced = target || worker
    {module, function, arity} = mfa
    Code.ensure_loaded!(module)
    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(traced, true, [:call, {:tracer, parent}])

    try do
      send(worker, :run)
      result = receive do: ({:result, ^worker, result} -> result)
      delivery = :erlang.trace_delivered(traced)
      receive_barrier({:trace_delivered, ^traced, ^delivery})
      {result, collect_calls(traced, module, function, arity, 0)}
    after
      :erlang.trace(traced, false, [:call])
      :erlang.trace_pattern(mfa, false, [:local])
      send(worker, :stop)
    end
  end

  defp collect_calls(pid, module, function, arity, count) do
    receive do
      {:trace, ^pid, :call, {^module, ^function, args}} when length(args) == arity ->
        collect_calls(pid, module, function, arity, count + 1)
    after
      0 -> count
    end
  end
end
