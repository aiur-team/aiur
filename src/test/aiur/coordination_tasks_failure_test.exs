defmodule Aiur.CoordinationTasksFailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.CoordinationTasks

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

    # Bound the *emitted detail* rather than the whole capture: `capture_log/1`
    # captures the global Logger, so a total-size assertion is falsifiable by any
    # unrelated process that happens to log during this block (#1747).
    longest_detail_run =
      ~r/x+/
      |> Regex.scan(log)
      |> Enum.map(fn [run] -> byte_size(run) end)
      |> Enum.max(fn -> 0 end)

    assert longest_detail_run > 0, "expected the failure detail to be logged"
    assert longest_detail_run <= 500
  end

  defp blocking_operation(test_pid) do
    fn ->
      send(test_pid, {:started, self()})
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
