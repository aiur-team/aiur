defmodule Aiur.Orchestrator.LifecycleFenceExpiryTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, AgentQueue, AgentQueueStore, AlertFeed, Issue}
  alias Aiur.Orchestrator.{AgentTeardown, Dispatcher, LifecycleFence, LifecycleFenceExpiry, PauseResume, State, StatusReport}

  test "a never-acknowledged fence expires on the dispatch poll and dispatches rework with its input" do
    {state, issue, item} = fenced_state(:completed)
    assert {:fenced, _} = LifecycleFence.reconcile_observed_state(state, issue)
    {store, _} = AgentQueueStore.claim_next_deliverable(state.queue_store, issue.identifier)
    state = %{state | queue_store: store}
    state = put_in(state.running[issue.id].lifecycle_fence.opened_at, DateTime.add(DateTime.utc_now(), -120, :second))
    parent = self()

    next =
      Dispatcher.maybe_dispatch(
        state,
        fn current ->
          assert :admit = LifecycleFence.reconcile_observed_state(current, issue)
          refute Map.has_key?(current.running[issue.id], :lifecycle_fence)

          PauseResume.dispatch_completed_replacement(current, current.running[issue.id], issue,
            admit_fun: fn current, _, _ -> {:ok, current} end,
            replace_fun: fn current, entry, issue, host ->
              PauseResume.replace_admitted_completed_entry(current, entry, issue, host, fn current, issue, attempt, host ->
                Dispatcher.do_dispatch_issue(current, issue, attempt, host,
                  rework_head_sha: "head",
                  runner: fn dispatched, _, _ ->
                    send(parent, {:rework_dispatched, dispatched})

                    receive do
                      :stop -> :ok
                    end
                  end
                )
              end)
            end
          )
        end,
        fn current -> {:ok, current} end
      )

    runner_pid = next.running[issue.id].pid
    on_exit(fn -> if Process.alive?(runner_pid), do: Process.exit(runner_pid, :kill) end)
    receive_barrier({:rework_dispatched, dispatched})
    assert dispatched.id == issue.id
    assert dispatched.state == "rework"
    assert next.running[issue.id].control.status == :working
    {_, delivered} = AgentQueueStore.claim_next_deliverable(next.queue_store, issue.identifier)
    assert delivered.id == item.id
    assert delivered.body == item.body
    assert delivered.provider_delivered_at == nil
    [alert] = Enum.filter(AlertFeed.list(), &(&1["topic"] == "ticket.#{issue.identifier}.agent.lifecycle_fence_expired"))
    assert alert["reason"] =~ "pending_item_ids=[#{item.id}]"
    assert alert["needs_attention"] == true
  end

  test "the two-minute boundary releases once and preserves a live provider's claim" do
    {state, issue, item} = fenced_state(:working)
    {store, _} = AgentQueueStore.claim_next_deliverable(state.queue_store, issue.identifier)
    state = %{state | queue_store: store}
    opened_at = state.running[issue.id].lifecycle_fence.opened_at
    assert LifecycleFenceExpiry.reconcile(state, DateTime.add(opened_at, 119, :second)) == state
    next = LifecycleFenceExpiry.reconcile(state, DateTime.add(opened_at, 120, :second))
    refute Map.has_key?(next.running[issue.id], :lifecycle_fence)
    assert AgentQueueStore.get(next.queue_store, item.id).status == :delivered
    assert next.queue_store == store
    assert LifecycleFenceExpiry.reconcile(next, DateTime.add(opened_at, 121, :second)) == next
  end

  test "completed workers retry failed input without replaying acknowledged delivery" do
    {state, issue, item} = fenced_state(:completed)
    {store, _} = AgentQueueStore.mark_failed(state.queue_store, item.id, :provider_down)
    {store, acknowledged} = AgentQueueStore.enqueue(store, AgentQueue.operator_message(issue.identifier, "acknowledged"))
    {store, _} = AgentQueueStore.claim_next_deliverable(store, issue.identifier)
    {store, _} = AgentQueueStore.mark_provider_delivered(store, acknowledged.id, %{turn_id: "turn"})
    state = LifecycleFence.protect_queued_item(%{state | queue_store: store}, issue.identifier, acknowledged)
    opened_at = state.running[issue.id].lifecycle_fence.opened_at
    next = LifecycleFenceExpiry.reconcile(state, DateTime.add(opened_at, 120, :second))
    assert AgentQueueStore.get(next.queue_store, item.id).status == :pending
    assert AgentQueueStore.get(next.queue_store, acknowledged.id) == AgentQueueStore.get(store, acknowledged.id)
  end

  test "new input and observed rework do not renew an existing delivery deadline" do
    {state, issue, _} = fenced_state(:working)
    opened_at = DateTime.add(DateTime.utc_now(), -60, :second)
    state = put_in(state.running[issue.id].lifecycle_fence.opened_at, opened_at)
    state = put_in(state.running[issue.id].lifecycle_fence.authoritative_state, "in-progress")
    {store, second} = AgentQueueStore.enqueue(state.queue_store, AgentQueue.operator_message(issue.identifier, "second"))
    state = LifecycleFence.protect_queued_item(%{state | queue_store: store}, issue.identifier, second)
    assert state.running[issue.id].lifecycle_fence.opened_at == opened_at
    assert {:fenced, next} = LifecycleFence.reconcile_observed_state(state, issue)
    assert next.running[issue.id].lifecycle_fence.opened_at == opened_at
    assert next.running[issue.id].lifecycle_fence.pending_item_ids == MapSet.new([1, 2])
  end

  test "expiry keeps a live worker's failed input deliverable for subsequent rework" do
    {state, issue, item} = fenced_state(:working)
    {store, _} = AgentQueueStore.mark_failed(state.queue_store, item.id, :provider_down)
    state = %{state | queue_store: store}
    opened_at = state.running[issue.id].lifecycle_fence.opened_at
    next = LifecycleFenceExpiry.reconcile(state, DateTime.add(opened_at, 120, :second))
    refute Map.has_key?(next.running[issue.id], :lifecycle_fence)
    {_, retry} = AgentQueueStore.claim_next_deliverable(next.queue_store, issue.identifier)
    assert retry.id == item.id
    assert retry.body == item.body
  end

  test "CLI agents, status and watch expose concrete pending IDs and their age" do
    {state, issue, item} = fenced_state(:completed)
    payload = StatusReport.snapshot_payload(state)
    [row] = StatusReport.agent_statuses(state)
    assert row.waiting.pending_item_ids == [item.id]
    assert row.waiting.age_ms >= 0
    fleet = {:ok, Map.put(payload, :statuses, [row]), %{status: :current, age_seconds: 0}}

    for command <- [&AgentControlCLI.agents/1, &AgentControlCLI.status/1, &AgentControlCLI.watch/1] do
      output = capture_io(fn -> command.(fleet_view: fleet, mode: :full) end)
      assert output =~ "pending_item_ids=[#{item.id}]"
      assert output =~ ~r/LifecycleFence · \d+s/
      assert output =~ issue.identifier
    end
  end

  test "forced teardown after expiry restores unacknowledged live claims for later rework" do
    for teardown <- [&AgentTeardown.deactivate_running_issue(&1, &2), &AgentTeardown.terminate_running_issue(&1, &2, false)] do
      {state, issue, item} = fenced_state(:working)
      {store, _} = AgentQueueStore.claim_next_deliverable(state.queue_store, issue.identifier)
      {:ok, pid} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      ref = Process.monitor(pid)
      state = %{state | queue_store: store}
      state = put_in(state.running[issue.id].pid, pid)
      state = put_in(state.running[issue.id].ref, ref)
      opened_at = state.running[issue.id].lifecycle_fence.opened_at
      expired = LifecycleFenceExpiry.reconcile(state, DateTime.add(opened_at, 120, :second))
      assert AgentQueueStore.get(expired.queue_store, item.id).status == :delivered
      next = teardown.(expired, issue.id)
      refute Process.alive?(pid)
      {_, retry} = AgentQueueStore.claim_next_deliverable(next.queue_store, issue.identifier)
      assert retry.id == item.id
      assert retry.body == item.body
    end
  end

  defp fenced_state(status) do
    issue = %Issue{id: "expiry", identifier: "LF-EXPIRY", state: "rework", title: "Rework"}
    entry = %{pid: nil, ref: nil, identifier: issue.identifier, issue: issue, session_id: "session", started_at: DateTime.utc_now(), control: %{status: status}}
    {store, item} = AgentQueueStore.enqueue(AgentQueueStore.new(), AgentQueue.operator_message(issue.identifier, "fix the review"))
    state = %State{queue_store: store, running: %{issue.id => entry}, claimed: MapSet.new([issue.id]), max_concurrent_agents: 2, effective_concurrent_agents: 2}
    {LifecycleFence.protect_queued_item(state, issue.identifier, item), issue, item}
  end
end
