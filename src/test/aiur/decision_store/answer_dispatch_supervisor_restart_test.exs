Code.require_file("../../support/decision_store_case.ex", __DIR__)

defmodule Aiur.DecisionStore.AnswerDispatchSupervisorRestartTest do
  use Aiur.DecisionStoreCase, async: false

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, :worker, _modules} -> pid
      _child -> nil
    end)
  end

  describe "dispatch supervisor restarts" do
    test "coordinator restart fails active and queued work and allows explicit retry", %{dir: dir} do
      parent = self()
      coordinator = unique_coordinator_name("Restart")
      task_supervisor = start_supervised!({Task.Supervisor, name: unique_coordinator_name("RestartTasks")})
      shared_task_supervisor = unique_coordinator_name("RestartSharedTasks")
      earlier_sibling = unique_coordinator_name("RestartEarlierSibling")

      {:ok, shared_root} =
        Supervisor.start_link(
          [
            Supervisor.child_spec({Agent, fn -> :ready end}, id: earlier_sibling),
            {Task.Supervisor, name: shared_task_supervisor}
          ],
          strategy: :rest_for_one
        )

      Process.unlink(shared_root)

      on_exit(fn ->
        if Process.alive?(shared_root), do: Supervisor.stop(shared_root, :normal)
      end)

      earlier_sibling_pid = child_pid(shared_root, earlier_sibling)
      shared_task_supervisor_pid = Process.whereis(shared_task_supervisor)
      shared_task_supervisor_ref = Process.monitor(shared_task_supervisor_pid)

      coordinator_pid =
        start_supervised!(
          {DecisionDispatchTasks, name: coordinator, max_concurrency: 1, task_starter: fn operation -> {:ok, Task.Supervisor.async(task_supervisor, operation)} end},
          id: coordinator
        )

      dispatcher = fn dispatched, opts ->
        if String.ends_with?(opts[:attempt_id], ":1") do
          send(parent, {:restart_dispatch_started, dispatched.decision_id, self()})
          receive do: (:never -> :ok)
        else
          send(parent, {:restart_retry_started, dispatched.decision_id, opts[:attempt_id]})
          {:ok, %{status: :accepted, item: %{id: 601}}}
        end
      end

      pid =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      decisions =
        for source <- ["restart-active", "restart-queued"] do
          assert {:ok, %{decision: decision}} = request(pid, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, %{action: action}} = answer(pid, decision.decision_id, payload)
          {decision, action}
        end

      [{active, _active_action}, {queued, queued_action}] = decisions
      assert_receive {:restart_dispatch_started, active_id, orphaned_worker}, 1_000
      assert active_id == active.decision_id
      wait_for_dispatch_count(pid, 2)

      # Force the shared Task.Supervisor's :rest_for_one restart in the exact
      # gap that used to precede Process.monitor/1. The private worker must
      # remain alive; using the shared supervisor here makes the strict :killed
      # assertion below fail because its late monitor sees :noproc.
      Process.exit(earlier_sibling_pid, :kill)
      assert_receive {:DOWN, ^shared_task_supervisor_ref, :process, ^shared_task_supervisor_pid, :shutdown}, 1_000
      restarted_shared_task_supervisor = wait_for_named_process(shared_task_supervisor, shared_task_supervisor_pid)
      assert restarted_shared_task_supervisor != shared_task_supervisor_pid

      orphaned_worker_ref = Process.monitor(orphaned_worker)

      Process.exit(coordinator_pid, :kill)
      assert_receive {:DOWN, ^orphaned_worker_ref, :process, ^orphaned_worker, :killed}, 1_000

      for {decision, _action} <- decisions do
        failed = wait_for_decision(pid, decision.decision_id, &(&1.delivery_status == :failed))
        assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_coordinator_exit"
      end

      restarted = wait_for_named_process(coordinator, coordinator_pid)
      assert Process.alive?(restarted)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(queued.decision_id, queued_action.action_id, pid)
      assert_receive {:restart_retry_started, queued_id, retry_attempt_id}, 1_000
      assert queued_id == queued.decision_id
      assert String.ends_with?(retry_attempt_id, ":2")

      settled = wait_for_decision(pid, queued.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
    end

    test "rest_for_one restart can kill a dispatch worker before a late monitor", %{dir: dir} do
      parent = self()
      blocker_id = unique_coordinator_name("EarlierSibling")
      task_supervisor = unique_coordinator_name("SharedTasks")
      coordinator = unique_coordinator_name("SharedCoordinator")

      children = [
        Supervisor.child_spec({Agent, fn -> :ready end}, id: blocker_id),
        {Task.Supervisor, name: task_supervisor}
      ]

      {:ok, root} = Supervisor.start_link(children, strategy: :rest_for_one)
      Process.unlink(root)

      on_exit(fn ->
        if Process.alive?(root), do: Supervisor.stop(root, :normal)
      end)

      blocker_pid = child_pid(root, blocker_id)
      assert is_pid(blocker_pid)
      task_supervisor_pid = Process.whereis(task_supervisor)

      coordinator_pid =
        start_supervised!(
          {DecisionDispatchTasks, name: coordinator, task_starter: fn operation -> {:ok, Task.Supervisor.async(task_supervisor, operation)} end},
          id: coordinator
        )

      task_supervisor_ref = Process.monitor(task_supervisor_pid)

      dispatcher = fn _decision, _opts ->
        send(parent, {:cascade_worker_started, self()})
        receive do: (:never -> :ok)
      end

      store = start_store!(dir, decision_dispatch_tasks: coordinator, dispatcher: dispatcher, dispatch_delay_ms: 0)
      assert {:ok, %{decision: decision}} = request(store, answerable_request("cascade-worker"))
      payload = %{"idempotency_key" => "cascade-worker", "expected_version" => 1, "option_id" => "ship"}
      assert {:ok, _result} = answer(store, decision.decision_id, payload)
      assert_receive {:cascade_worker_started, worker}, 1_000

      worker_links = Process.info(worker, :links) |> elem(1)
      assert coordinator_pid in worker_links
      assert task_supervisor_pid in worker_links
      worker_ref = Process.monitor(worker)

      Process.exit(blocker_pid, :kill)

      assert_receive {:DOWN, ^task_supervisor_ref, :process, ^task_supervisor_pid, :shutdown}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :shutdown}, 1_000

      # The worker links to both pids above; the coordinator remains alive, so
      # the old Task.Supervisor is the process that ended this worker.
      late_worker_ref = Process.monitor(worker)
      assert_receive {:DOWN, ^late_worker_ref, :process, ^worker, :noproc}, 1_000

      restarted_task_supervisor = wait_for_named_process(task_supervisor, task_supervisor_pid)
      assert Process.alive?(coordinator_pid)
      assert restarted_task_supervisor != task_supervisor_pid
    end
  end
end
