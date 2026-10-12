defmodule Aiur.Orchestrator.Status.CompletedRunnerTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorStatusSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PauseResume
  alias Aiur.Orchestrator.State

  test "completed runner releases its slot and an Executor message schedules replacement" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedOperatorMessageOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    parent = self()
    {:ok, old_worker} = supervised_operator_message_probe(parent)
    old_ref = Process.monitor(old_worker)

    issue =
      %Issue{
        id: "issue-completed",
        identifier: "MT-COMPLETED",
        state: "rework",
        title: "Completed message replacement"
      }

    release_file = configure_completed_revalidation!([issue])

    on_exit(fn ->
      File.touch(release_file)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      entry =
        "issue-completed"
        |> running_entry("MT-COMPLETED", :working, old_worker)
        |> Map.put(:ref, old_ref)
        |> Map.put(:issue, issue)

      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{"issue-completed" => entry},
          claimed: MapSet.put(state.claimed, "issue-completed")
      }
    end)

    send(pid, {:worker_control_state, "issue-completed", :completed})

    assert %{active: 0} = Orchestrator.max_concurrent_agents(orchestrator_name)

    assert %{running: [%{work_state: :completed, waiting_reason: :awaiting_dispatch}]} =
             GenServer.call(orchestrator_name, :snapshot)

    assert {:error, :already_inactive} = Orchestrator.pause_agent(orchestrator_name, "MT-COMPLETED")

    item_ids =
      for body <- ["first repair", "second repair", "third repair"] do
        assert {:ok, item_id} =
                 Orchestrator.send_operator_message(orchestrator_name, "MT-COMPLETED", %{
                   kind: :text,
                   body: body
                 })

        item_id
      end

    receive_barrier({:DOWN, ^old_ref, :process, ^old_worker, _reason})
    refute Process.alive?(old_worker)

    state = :sys.get_state(pid)
    replacement = Map.fetch!(state.running, "issue-completed")

    assert is_pid(replacement.pid)
    assert Process.alive?(replacement.pid)
    assert replacement.pid != old_worker
    assert is_reference(replacement.ref)
    assert replacement.ref != old_ref
    assert replacement.control.status == :working
    assert state.queue_store.pending_ids_by_target["MT-COMPLETED"] == item_ids

    assert Enum.map(item_ids, &state.queue_store.items[&1].body.text) == [
             "first repair",
             "second repair",
             "third repair"
           ]

    send(pid, {:DOWN, old_ref, :process, old_worker, :normal})
    after_stale_down = :sys.get_state(pid)

    assert after_stale_down.running["issue-completed"].pid == replacement.pid
    assert after_stale_down.running["issue-completed"].ref == replacement.ref
    refute Map.has_key?(after_stale_down.retry_attempts, "issue-completed")
  end

  test "explicit resume replaces a completed runner instead of waking its returned task" do
    orchestrator_name = Module.concat(__MODULE__, :CompletedResumeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    freeze_poll_cycle(pid)
    {:ok, old_worker} = supervised_operator_message_probe(self())
    old_ref = Process.monitor(old_worker)

    issue = %Issue{
      id: "issue-completed-resume",
      identifier: "MT-COMPLETED-RESUME",
      state: "rework",
      title: "Completed explicit resume"
    }

    release_file = configure_completed_revalidation!([issue])

    on_exit(fn ->
      File.touch(release_file)
      SubscriptionStore.stop(issue.identifier)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    :sys.replace_state(pid, fn state ->
      entry =
        "issue-completed-resume"
        |> running_entry("MT-COMPLETED-RESUME", :completed, old_worker)
        |> Map.put(:ref, old_ref)
        |> Map.put(:issue, issue)

      %{
        state
        | session_max_concurrent_agents: 1,
          running: %{"issue-completed-resume" => entry},
          claimed: MapSet.put(state.claimed, "issue-completed-resume")
      }
    end)

    assert {:ok, :started} = Orchestrator.resume_agent(orchestrator_name, "MT-COMPLETED-RESUME")
    refute Process.alive?(old_worker)

    state = :sys.get_state(pid)
    replacement = Map.fetch!(state.running, "issue-completed-resume")
    assert is_pid(replacement.pid) and Process.alive?(replacement.pid)
    assert replacement.pid != old_worker
    assert is_reference(replacement.ref)
    assert replacement.ref != old_ref
    refute Map.has_key?(state.retry_attempts, "issue-completed-resume")
  end

  test "tracker revalidation retains completed runners and messages for inactive states" do
    current_issues = [
      %Issue{id: "inactive-review", identifier: "MT-INACTIVE-REVIEW", state: "human-review", title: "Review"},
      %Issue{id: "inactive-ci", identifier: "MT-INACTIVE-CI", state: "ci-wait", title: "CI"},
      %Issue{id: "inactive-done", identifier: "MT-INACTIVE-DONE", state: "done", title: "Done"},
      %Issue{id: "inactive-paused", identifier: "MT-INACTIVE-PAUSED", state: "rework", title: "Paused", paused: true}
    ]

    release_file = configure_completed_revalidation!(current_issues)

    completed =
      Map.new(current_issues, fn current_issue ->
        {:ok, worker} = supervised_operator_message_probe(self())
        ref = Process.monitor(worker)
        cached_issue = %{current_issue | state: "rework", paused: false}

        entry =
          current_issue.id
          |> running_entry(current_issue.identifier, :completed, worker)
          |> Map.put(:ref, ref)
          |> Map.put(:issue, cached_issue)

        {current_issue.id, {worker, ref, entry}}
      end)

    on_exit(fn ->
      File.touch(release_file)

      Enum.each(completed, fn {_issue_id, {worker, _ref, _entry}} ->
        if Process.alive?(worker), do: Process.exit(worker, :kill)
      end)
    end)

    entries = Map.new(completed, fn {issue_id, {_worker, _ref, entry}} -> {issue_id, entry} end)

    initial_state = %State{
      running: entries,
      claimed: MapSet.new(Map.keys(entries)),
      max_concurrent_agents: 4
    }

    {item_ids, state} =
      Enum.reduce(current_issues, {%{}, initial_state}, fn issue, {ids, state} ->
        assert {{:ok, item_id}, next_state} =
                 OperatorMessages.enqueue_operator_message(
                   state,
                   issue.identifier,
                   "retain #{issue.id}",
                   %{}
                 )

        {Map.put(ids, issue.id, item_id), next_state}
      end)

    Enum.each(current_issues, fn current_issue ->
      {worker, ref, original_entry} = completed[current_issue.id]
      retained = Map.fetch!(state.running, current_issue.id)

      assert Process.alive?(worker)
      assert retained.pid == worker
      assert retained.ref == ref
      assert retained.control.status == :completed
      assert retained.session_id == original_entry.session_id
      assert retained.worker_host == original_entry.worker_host
      assert retained.issue.state == current_issue.state
      assert retained.issue.paused == current_issue.paused
      assert MapSet.member?(state.claimed, current_issue.id)
      assert state.queue_store.pending_ids_by_target[current_issue.identifier] == [item_ids[current_issue.id]]
      refute Map.has_key?(state.retry_attempts, current_issue.id)
    end)
  end

  test "failed admitted spawn restores the completed row, claim, identity, and FIFO queue" do
    issue = %Issue{
      id: "spawn-failure-completed",
      identifier: "MT-SPAWN-FAILURE",
      state: "rework",
      title: "Retain completed spawn failure"
    }

    {:ok, old_worker} = supervised_operator_message_probe(self())
    old_ref = Process.monitor(old_worker)

    on_exit(fn ->
      if Process.alive?(old_worker), do: Process.exit(old_worker, :kill)
    end)

    entry =
      issue.id
      |> running_entry(issue.identifier, :completed, old_worker, "worker-a")
      |> Map.put(:ref, old_ref)
      |> Map.put(:issue, issue)
      |> Map.put(:session_id, "thread-preserved")
      |> Map.put(:started_at, DateTime.add(DateTime.utc_now(), -30, :second))

    {queue_store, first} =
      AgentQueueStore.enqueue(%AgentQueueStore{}, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "first"}
      })

    {queue_store, second} =
      AgentQueueStore.enqueue(queue_store, %{
        target_issue_identifier: issue.identifier,
        source: :operator,
        category: :operator_message,
        event_type: :operator_message,
        body: %{text: "second"}
      })

    state = %State{
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id]),
      queue_store: queue_store,
      max_concurrent_agents: 2
    }

    spawn_failure = fn torn_state, _issue, _attempt, _worker_host ->
      %{torn_state | retry_attempts: %{issue.id => %{attempt: 1}}}
    end

    {result, next} =
      PauseResume.replace_admitted_completed_entry_result(
        state,
        entry,
        issue,
        "worker-a",
        spawn_failure
      )

    assert {:error, {:redispatch_deferred, {:worker_start_failed, %{attempt: 1}}}} = result
    refute Process.alive?(old_worker)
    restored = Map.fetch!(next.running, issue.id)
    assert restored.pid == nil
    assert restored.ref == nil
    assert restored.control.status == :completed
    assert restored.session_id == "thread-preserved"
    assert restored.worker_host == "worker-a"
    assert restored.completed_provenance
    assert restored.completion_totals_recorded
    assert MapSet.member?(next.claimed, issue.id)
    assert next.queue_store.pending_ids_by_target[issue.identifier] == [first.id, second.id]
    refute Map.has_key?(next.retry_attempts, issue.id)

    first_totals = next.agent_totals
    assert first_totals.seconds_running >= 30

    repeated =
      PauseResume.replace_admitted_completed_entry(
        next,
        restored,
        issue,
        "worker-a",
        spawn_failure
      )

    assert repeated.agent_totals == first_totals
    assert repeated.running[issue.id].completion_totals_recorded
    assert repeated.queue_store.pending_ids_by_target[issue.identifier] == [first.id, second.id]
  end
end
