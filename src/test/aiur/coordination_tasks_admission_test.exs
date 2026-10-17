defmodule Aiur.CoordinationTasksAdmissionTest do
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

  test "task-start retries and warnings coalesce while the supervisor is unavailable" do
    name = unique_name("TaskStartCoalesced")
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    task_starter = fn _entry ->
      Agent.update(attempts, &(&1 + 1))
      send(test_pid, :task_start_attempted)
      exit(:task_supervisor_unavailable)
    end

    start_supervised!({CoordinationTasks, name: name, task_starter: task_starter, task_start_retry_ms: 2_000, task_start_retry_max_ms: 2_000})

    log =
      capture_log(fn ->
        assert :pending = CoordinationTasks.enqueue(:first, fn -> :ok end, name)
        assert_receive :task_start_attempted, 2_000

        for key <- 2..20 do
          assert :pending = CoordinationTasks.enqueue(key, fn -> :ok end, name)
        end

        assert Agent.get(attempts, & &1) == 1
      end)

    assert length(String.split(log, "coordination task start failed")) == 2
  end

  test "absence and restart loss return coordination unavailable" do
    name = unique_name("Absent")
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, [], 20)
    assert {:error, :coordination_unavailable} = CoordinationTasks.run(:key, fn -> :ok end, name, [], 20)

    child = Supervisor.child_spec({CoordinationTasks, name: name}, restart: :temporary)
    pid = start_supervised!(child)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, [], 20)
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

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
