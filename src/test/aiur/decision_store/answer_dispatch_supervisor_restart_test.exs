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
      root = Process.whereis(Aiur.Supervisor)
      shared_task_supervisor = Process.whereis(Aiur.TaskSupervisor)
      root_ref = Process.monitor(root)
      shared_task_supervisor_ref = Process.monitor(shared_task_supervisor)

      on_exit(fn ->
        if Process.alive?(root), do: :sys.trace(root, false)
      end)

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

      store =
        start_store!(dir,
          decision_dispatch_tasks: coordinator,
          dispatcher: dispatcher,
          dispatch_delay_ms: 0
        )

      decisions =
        for source <- ["restart-active", "restart-queued"] do
          assert {:ok, %{decision: decision}} = request(store, answerable_request(source))
          payload = %{"idempotency_key" => source, "expected_version" => 1, "option_id" => "ship"}
          assert {:ok, %{action: action}} = answer(store, decision.decision_id, payload)
          {decision, action}
        end

      [{active, _active_action}, {queued, queued_action}] = decisions
      assert_receive {:restart_dispatch_started, active_id, worker}, 1_000
      assert active_id == active.decision_id
      worker_links = Process.info(worker, :links) |> elem(1)
      assert coordinator_pid in worker_links
      assert Enum.any?([task_supervisor, shared_task_supervisor], &(&1 in worker_links))
      worker_ref = Process.monitor(worker)

      :ok = :sys.trace(root, true)
      wait_for_dispatch_count(store, 2)
      :ok = :sys.trace(root, false)

      IO.puts(
        "original dispatch root=#{inspect(root)} shared_task_supervisor=#{inspect(shared_task_supervisor)} " <>
          "worker=#{inspect(worker)} worker_links=#{inspect(worker_links)}"
      )

      coordinator_ref = Process.monitor(coordinator_pid)
      Process.exit(coordinator_pid, :kill)
      assert_receive {:DOWN, ^coordinator_ref, :process, ^coordinator_pid, :killed}, 1_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
      refute_receive {:DOWN, ^shared_task_supervisor_ref, :process, ^shared_task_supervisor, _reason}, 0
      assert Process.alive?(shared_task_supervisor)
      refute_receive {:DOWN, ^root_ref, :process, ^root, _reason}, 0

      IO.puts(
        "original dispatch worker_exit=:killed killer_coordinator=#{inspect(coordinator_pid)} " <>
          "shared_task_supervisor_still_alive=#{inspect(shared_task_supervisor)}"
      )

      for {decision, _action} <- decisions do
        failed = wait_for_decision(store, decision.decision_id, &(&1.delivery_status == :failed))
        assert List.last(failed.dispatch_attempts).failure_reason_class == "decision_dispatch_coordinator_exit"
      end

      restarted = wait_for_named_process(coordinator, coordinator_pid)
      assert Process.alive?(restarted)

      assert {:ok, :scheduled} = DecisionStore.retry_dispatch(queued.decision_id, queued_action.action_id, store)
      assert_receive {:restart_retry_started, queued_id, retry_attempt_id}, 1_000
      assert queued_id == queued.decision_id
      assert String.ends_with?(retry_attempt_id, ":2")

      settled = wait_for_decision(store, queued.decision_id, &(&1.delivery_status == :queued))
      assert Enum.map(settled.dispatch_attempts, & &1.status) == [:failed, :queued]
    end

    test "real root restart leaves a private dispatch worker alive", %{original_decision_state_dir: original_decision_state_dir} do
      parent = self()
      coordinator = unique_coordinator_name("RootRestart")
      task_supervisor = start_supervised!({Task.Supervisor, name: unique_coordinator_name("RootRestartTasks")})
      root = Process.whereis(Aiur.Supervisor)
      shared_task_supervisor = Process.whereis(Aiur.TaskSupervisor)
      earlier_sibling = Aiur.Workspace.Ownership.Reconciler
      earlier_sibling_pid = child_pid(root, earlier_sibling)

      assert is_pid(root)
      assert is_pid(shared_task_supervisor)
      assert is_pid(earlier_sibling_pid)
      root_ref = Process.monitor(root)
      shared_task_supervisor_ref = Process.monitor(shared_task_supervisor)

      on_exit(fn ->
        if Process.alive?(root), do: :sys.trace(root, false)
      end)

      coordinator_pid =
        start_supervised!(
          {DecisionDispatchTasks, name: coordinator, max_concurrency: 1, task_starter: fn operation -> {:ok, Task.Supervisor.async(task_supervisor, operation)} end},
          id: coordinator
        )

      operation = fn ->
        send(parent, {:root_restart_worker_started, self()})
        receive do: (:never -> :ok)
      end

      assert :pending =
               DecisionDispatchTasks.enqueue(
                 "ticket.5146",
                 :root_restart,
                 operation,
                 fn correlation, result -> send(parent, {:dispatch_result, correlation, result}) end,
                 coordinator
               )

      assert_receive {:root_restart_worker_started, worker}, 1_000

      worker_links = Process.info(worker, :links) |> elem(1)
      assert coordinator_pid in worker_links
      assert Enum.any?([task_supervisor, shared_task_supervisor], &(&1 in worker_links))
      worker_ref = Process.monitor(worker)

      IO.puts(
        "forced restart root=#{inspect(root)} sibling=#{inspect(earlier_sibling)} " <>
          "sibling_pid=#{inspect(earlier_sibling_pid)} task_supervisor=#{inspect(shared_task_supervisor)} " <>
          "worker=#{inspect(worker)} worker_links=#{inspect(worker_links)}"
      )

      # The kill reboots the global DecisionStore under rest_for_one; it must
      # come back on the suite's state dir, not this test's soon-deleted one.
      case original_decision_state_dir do
        nil -> Application.delete_env(:aiur, :decision_state_dir)
        value -> Application.put_env(:aiur, :decision_state_dir, value)
      end

      :ok = :sys.trace(root, true)
      Process.exit(earlier_sibling_pid, :kill)

      assert_receive {:DOWN, ^shared_task_supervisor_ref, :process, ^shared_task_supervisor, task_supervisor_exit}, 1_000
      # The root replies only after restarting every later sibling, so this
      # outlasts a slow restart and the next test never meets a half-built tree.
      _children = Supervisor.which_children(root)
      restarted_shared_task_supervisor = Process.whereis(Aiur.TaskSupervisor)
      :ok = :sys.trace(root, false)
      assert task_supervisor_exit == :shutdown
      assert restarted_shared_task_supervisor != shared_task_supervisor

      worker_exit =
        receive do
          {:DOWN, ^worker_ref, :process, ^worker, reason} -> {:down, reason}
        after
          100 -> :alive
        end

      IO.puts(
        "forced restart Aiur.TaskSupervisor old_pid=#{inspect(shared_task_supervisor)} " <>
          "exit_reason=#{inspect(task_supervisor_exit)} restarted_pid=#{inspect(restarted_shared_task_supervisor)} " <>
          "worker_exit=#{inspect(worker_exit)}"
      )

      assert Process.alive?(root)
      refute_receive {:DOWN, ^root_ref, :process, ^root, _reason}, 0
      assert worker_exit == :alive

      Process.exit(coordinator_pid, :kill)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    end
  end
end
