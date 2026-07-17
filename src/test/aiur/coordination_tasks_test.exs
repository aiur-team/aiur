defmodule Aiur.CoordinationTasksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.CoordinationTasks

  test "same-key operations retain admission order" do
    name = unique_name("Ordered")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:ticket_a, blocking_operation(test_pid), name)
    assert :pending = CoordinationTasks.enqueue(:ticket_a, fn -> send(test_pid, :second_started) end, name)
    assert_receive {:started, first}, 2_000
    state = :sys.get_state(name)
    assert :queue.len(Map.fetch!(state.queues, :ticket_a)) == 1
    send(first, :release)
    assert_receive :second_started, 2_000
  end

  test "a stalled key does not delay an independent key" do
    name = unique_name("Parallel")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 2})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:ticket_a, blocking_operation(test_pid), name)
    assert_receive {:started, first}, 2_000
    assert :pending = CoordinationTasks.enqueue(:ticket_b, fn -> send(test_pid, :ticket_b_started) end, name)
    assert_receive :ticket_b_started, 2_000
    send(first, :release)
  end

  test "accepted runnable keys are scheduled fairly" do
    name = unique_name("Fair")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 1})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:hot, blocking_operation(test_pid, :hot_first), name)
    assert_receive {:started, :hot_first, hot_first}, 2_000

    assert :pending = CoordinationTasks.enqueue(:hot, blocking_operation(test_pid, :hot_second), name)
    assert :pending = CoordinationTasks.enqueue(:waiting, blocking_operation(test_pid, :waiting), name)

    send(hot_first, :release)
    assert_receive {:started, :waiting, waiting}, 2_000

    send(waiting, :release)
    assert_receive {:started, :hot_second, hot_second}, 2_000
    send(hot_second, :release)
  end

  test "bounded admission rejects overload and recovers after work drains" do
    name = unique_name("Bounded")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 1, max_pending: 1})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:active, blocking_operation(test_pid), name)
    assert_receive {:started, first}, 2_000
    assert :pending = CoordinationTasks.enqueue(:queued, fn -> send(test_pid, :queued_ran) end, name)
    assert {:error, :coordination_overloaded} = CoordinationTasks.enqueue(:extra, fn -> :ok end, name)
    assert {:error, :coordination_overloaded} = CoordinationTasks.run(:extra, fn -> :ok end, name)

    send(first, :release)
    assert_receive :queued_ran, 2_000
    assert :pending = CoordinationTasks.enqueue(:recovered, fn -> send(test_pid, :recovered) end, name)
    assert_receive :recovered, 2_000
  end

  test "one stalled key cannot consume the final pending slot" do
    name = unique_name("ReservedCapacity")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 1, max_pending: 3})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:hot, blocking_operation(test_pid), name)
    assert_receive {:started, first}, 2_000
    assert :pending = CoordinationTasks.enqueue(:hot, fn -> send(test_pid, :hot_two) end, name)
    assert :pending = CoordinationTasks.enqueue(:hot, fn -> send(test_pid, :hot_three) end, name)

    assert {:error, :coordination_overloaded} =
             CoordinationTasks.enqueue(:hot, fn -> send(test_pid, :hot_four) end, name)

    assert :pending =
             CoordinationTasks.enqueue(:independent, fn -> send(test_pid, :independent_started) end, name)

    send(first, :release)
    assert_receive :independent_started, 2_000
  end

  test "acknowledged work survives a temporary task-start failure" do
    name = unique_name("TaskStartRetry")
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    task_starter = fn entry ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:task_start_attempt, attempt})

      if attempt == 1 do
        {:error, :task_supervisor_unavailable}
      else
        {:ok, Task.Supervisor.async(Aiur.TaskSupervisor, entry.operation)}
      end
    end

    start_supervised!({CoordinationTasks, name: name, task_starter: task_starter})

    assert :pending =
             CoordinationTasks.enqueue(:key, fn -> send(test_pid, :retained_operation_ran) end, name)

    assert_receive {:task_start_attempt, 1}, 2_000
    assert_receive {:task_start_attempt, 2}, 2_000
    assert_receive :retained_operation_ran, 2_000
    assert Agent.get(attempts, & &1) == 2
  end

  test "absence and restart loss return coordination unavailable" do
    name = unique_name("Absent")
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, [], 20)
    assert {:error, :coordination_unavailable} = CoordinationTasks.run(:key, fn -> :ok end, name, [], 20)

    pid = start_supervised!({CoordinationTasks, name: name})
    Process.exit(pid, :kill)
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, [], 20)
  end

  test "timed out admission is indeterminate and expired work never executes" do
    name = unique_name("AdmissionTimeout")
    pid = start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    :ok = :sys.suspend(pid)

    call =
      Task.async(fn ->
        CoordinationTasks.enqueue(:key, fn -> send(test_pid, :late_execution) end, name, [], 20)
      end)

    assert {:error, :coordination_indeterminate} = Task.await(call, 2_000)
    :ok = :sys.resume(pid)
    assert :barrier = CoordinationTasks.run(:barrier, fn -> :barrier end, name)
    refute_receive :late_execution, 0
  end

  test "run waits behind the keyed lane and returns the operation result" do
    name = unique_name("Awaited")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:key, blocking_operation(test_pid), name)
    assert_receive {:started, first}, 2_000

    call =
      Task.async(fn ->
        CoordinationTasks.run(
          :key,
          fn ->
            send(test_pid, :awaited_started)
            {:ok, :removed}
          end,
          name
        )
      end)

    assert :ok = wait_for_queued_entry(name, :key)
    send(first, :release)
    assert_receive :awaited_started, 2_000
    assert {:ok, :removed} = Task.await(call)
  end

  test "run normalizes raised, thrown, and exited operations" do
    name = unique_name("Failures")
    start_supervised!({CoordinationTasks, name: name})

    for {operation, expected} <- [
          {fn -> raise "broken" end, {:coordination_operation_exception, "broken"}},
          {fn -> throw(:rejected) end, {:coordination_operation_failure, :throw, :rejected}},
          {fn -> exit(:gone) end, {:coordination_operation_failure, :exit, :gone}}
        ] do
      assert {:error, ^expected} = CoordinationTasks.run(:key, operation, name)
    end
  end

  test "run reports an externally killed operation without killing the coordinator" do
    name = unique_name("KilledRun")
    coordinator = start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    call =
      Task.async(fn ->
        CoordinationTasks.run(
          :key,
          fn ->
            send(test_pid, {:killable_operation, self()})
            receive do: (:never_release -> :ok)
          end,
          name
        )
      end)

    assert_receive {:killable_operation, worker}, 2_000
    Process.exit(worker, :kill)
    assert {:error, {:coordination_task_exit, :killed}} = Task.await(call, 2_000)
    assert Process.alive?(coordinator)
  end

  test "coordinator death after a run starts is indeterminate" do
    name = unique_name("RunIndeterminate")
    coordinator = start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    call =
      Task.async(fn ->
        CoordinationTasks.run(
          :key,
          fn ->
            send(test_pid, :run_started)
            receive do: (:never_release -> :ok)
          end,
          name
        )
      end)

    assert_receive :run_started, 2_000
    Process.exit(coordinator, :kill)
    assert {:error, :coordination_indeterminate} = Task.await(call, 2_000)
  end

  test "an abnormal task exit leaves the coordinator and keyed lane available" do
    name = unique_name("TaskExit")
    coordinator = start_supervised!({CoordinationTasks, name: name})
    coordinator_ref = Process.monitor(coordinator)
    test_pid = self()

    assert :pending =
             CoordinationTasks.enqueue(
               :key,
               fn ->
                 send(test_pid, {:failing_task_started, self()})
                 receive do: (:never_release -> :ok)
               end,
               name
             )

    assert :pending =
             CoordinationTasks.enqueue(:key, fn -> send(test_pid, :lane_recovered) end, name)

    assert_receive {:failing_task_started, worker}, 2_000
    Process.exit(worker, :kill)
    assert_receive :lane_recovered, 2_000
    assert Process.alive?(coordinator)
    refute_receive {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason}, 0
  end

  test "coordinator restart terminates active work before reopening its key" do
    name = unique_name("Restart")
    {:ok, supervisor} = Supervisor.start_link([{CoordinationTasks, name: name}], strategy: :one_for_one)
    on_exit(fn -> Process.exit(supervisor, :shutdown) end)

    coordinator = Process.whereis(name)
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:key, blocking_operation(test_pid), name)
    assert_receive {:started, first}, 2_000
    first_ref = Process.monitor(first)

    Process.exit(coordinator, :kill)
    restarted = wait_for_restart(name, coordinator)
    assert is_pid(restarted)

    assert :pending =
             CoordinationTasks.enqueue(
               :key,
               fn -> send(test_pid, {:after_restart, Process.alive?(first)}) end,
               name
             )

    assert_receive {:after_restart, false}, 2_000
    assert_receive {:DOWN, ^first_ref, :process, ^first, _reason}, 2_000
  end

  test "timed out work releases its keyed lane" do
    name = unique_name("Timeout")
    start_supervised!({CoordinationTasks, name: name, operation_timeout_ms: 20})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:key, fn -> receive do: (:never_release -> :ok) end, name)
    assert :pending = CoordinationTasks.enqueue(:key, fn -> send(test_pid, :after_timeout) end, name)
    assert_receive :after_timeout, 2_000
  end

  test "infinite operation timeout preserves ordering past the default deadline" do
    name = unique_name("NoTimeout")
    start_supervised!({CoordinationTasks, name: name, operation_timeout_ms: 20})
    test_pid = self()

    assert :pending =
             CoordinationTasks.enqueue(:key, blocking_operation(test_pid), name, operation_timeout: :infinity)

    assert_receive {:started, first}, 2_000
    assert :pending = CoordinationTasks.enqueue(:key, fn -> send(test_pid, :second_started) end, name)
    state = :sys.get_state(name)
    assert :queue.len(Map.fetch!(state.queues, :key)) == 1
    send(first, :release)
    assert_receive :second_started, 2_000
  end

  test "terminal operation errors are logged before the lane advances" do
    name = unique_name("Error")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    log =
      capture_log(fn ->
        assert :pending =
                 CoordinationTasks.enqueue(
                   {:dependency, "1031", 999},
                   fn -> {:error, :terminal_failure} end,
                   name,
                   operation_timeout: 123,
                   log_context: %{issue_id: "gid-1031", issue_identifier: "AIUR-1031"}
                 )

        assert :pending =
                 CoordinationTasks.enqueue(
                   {:dependency, "1031", 999},
                   fn -> send(test_pid, :lane_advanced) end,
                   name
                 )

        assert_receive :lane_advanced, 2_000
      end)

    assert log =~ "coordination operation failed"
    assert log =~ ~s({:dependency, "1031", 999})
    assert log =~ ~s(ticket="1031")
    assert log =~ ~s(issue_id="gid-1031")
    assert log =~ ~s(issue_identifier="AIUR-1031")
    assert log =~ "terminal_failure"
    assert log =~ "timeout_ms=123"
  end

  test "distinct-key timeouts log their event key and configured timeout" do
    name = unique_name("CorrelatedTimeout")
    start_supervised!({CoordinationTasks, name: name, operation_timeout_ms: 500})
    test_pid = self()

    log =
      capture_log(fn ->
        assert :pending =
                 CoordinationTasks.enqueue(
                   {:event, "1032"},
                   fn -> receive do: (:never_release -> :ok) end,
                   name,
                   operation_timeout: 17,
                   log_context: %{issue_id: "gid-1032", issue_identifier: "AIUR-1032"}
                 )

        assert :pending =
                 CoordinationTasks.enqueue(
                   {:event, "1032"},
                   fn -> send(test_pid, :event_lane_advanced) end,
                   name
                 )

        assert_receive :event_lane_advanced, 2_000
      end)

    assert log =~ ~s({:event, "1032"})
    assert log =~ ~s(ticket="1032")
    assert log =~ ~s(issue_id="gid-1032")
    assert log =~ ~s(issue_identifier="AIUR-1032")
    assert log =~ "coordination_timeout"
    assert log =~ "timeout_ms=17"
    refute log =~ ~s({:dependency, "1031", 999})
  end

  test "failure logs redact secrets and bound failure details" do
    name = unique_name("SanitizedFailure")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()
    secret = "ghp_" <> String.duplicate("b", 36)

    log =
      capture_log(fn ->
        assert :pending =
                 CoordinationTasks.enqueue(
                   {:event, "internal-1033"},
                   fn -> {:error, {:publisher_failed, secret, String.duplicate("x", 2_000)}} end,
                   name,
                   operation_timeout: 456,
                   log_context: %{issue_id: "internal-1033", issue_identifier: "AIUR-1033"}
                 )

        assert :pending =
                 CoordinationTasks.enqueue(
                   {:event, "internal-1033"},
                   fn -> send(test_pid, :sanitized_lane_advanced) end,
                   name
                 )

        assert_receive :sanitized_lane_advanced, 2_000
      end)

    refute log =~ secret
    assert log =~ "[REDACTED:ghp]"
    assert log =~ ~s(issue_id="internal-1033")
    assert log =~ ~s(issue_identifier="AIUR-1033")
    assert log =~ "timeout_ms=456"
    assert byte_size(log) < 1_000
  end

  defp blocking_operation(test_pid) do
    fn ->
      send(test_pid, {:started, self()})
      receive do: (:release -> :ok)
    end
  end

  defp blocking_operation(test_pid, label) do
    fn ->
      send(test_pid, {:started, label, self()})
      receive do: (:release -> :ok)
    end
  end

  defp wait_for_restart(name, old_pid, attempts \\ 400)

  defp wait_for_restart(_name, _old_pid, 0), do: nil

  defp wait_for_restart(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        receive do
        after
          5 -> wait_for_restart(name, old_pid, attempts - 1)
        end
    end
  end

  defp wait_for_queued_entry(name, key, attempts \\ 400)

  defp wait_for_queued_entry(_name, _key, 0), do: :timeout

  defp wait_for_queued_entry(name, key, attempts) do
    state = :sys.get_state(name)

    case Map.get(state.queues, key) do
      queue when not is_nil(queue) ->
        if :queue.is_empty(queue), do: retry_queued_entry(name, key, attempts), else: :ok

      nil ->
        retry_queued_entry(name, key, attempts)
    end
  end

  defp retry_queued_entry(name, key, attempts) do
    receive do
    after
      5 -> wait_for_queued_entry(name, key, attempts - 1)
    end
  end

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
