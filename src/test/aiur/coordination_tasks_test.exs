defmodule Aiur.CoordinationTasksTest do
  use ExUnit.Case, async: true

  alias Aiur.CoordinationTasks

  test "same-key operations retain admission order" do
    name = unique_name("Ordered")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:ticket_a, blocking_operation(test_pid), name)
    assert :pending = CoordinationTasks.enqueue(:ticket_a, fn -> send(test_pid, :second_started) end, name)
    assert_receive {:started, first}
    refute_receive :second_started, 20
    send(first, :release)
    assert_receive :second_started
  end

  test "a stalled key does not delay an independent key" do
    name = unique_name("Parallel")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 2})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:ticket_a, blocking_operation(test_pid), name)
    assert_receive {:started, first}
    assert :pending = CoordinationTasks.enqueue(:ticket_b, fn -> send(test_pid, :ticket_b_started) end, name)
    assert_receive :ticket_b_started, 100
    send(first, :release)
  end

  test "bounded admission rejects overload and recovers after work drains" do
    name = unique_name("Bounded")
    start_supervised!({CoordinationTasks, name: name, max_concurrency: 1, max_pending: 1})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:active, blocking_operation(test_pid), name)
    assert_receive {:started, first}
    assert :pending = CoordinationTasks.enqueue(:queued, fn -> send(test_pid, :queued_ran) end, name)
    assert {:error, :coordination_overloaded} = CoordinationTasks.enqueue(:extra, fn -> :ok end, name)

    send(first, :release)
    assert_receive :queued_ran
    assert :pending = CoordinationTasks.enqueue(:recovered, fn -> send(test_pid, :recovered) end, name)
    assert_receive :recovered
  end

  test "absence and restart loss return coordination unavailable" do
    name = unique_name("Absent")
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, 20)

    pid = start_supervised!({CoordinationTasks, name: name})
    Process.exit(pid, :kill)
    assert {:error, :coordination_unavailable} = CoordinationTasks.enqueue(:key, fn -> :ok end, name, 20)
  end

  test "timed out work releases its keyed lane" do
    name = unique_name("Timeout")
    start_supervised!({CoordinationTasks, name: name, operation_timeout_ms: 20})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(:key, fn -> Process.sleep(:infinity) end, name)
    assert :pending = CoordinationTasks.enqueue(:key, fn -> send(test_pid, :after_timeout) end, name)
    assert_receive :after_timeout, 200
  end

  defp blocking_operation(test_pid) do
    fn ->
      send(test_pid, {:started, self()})
      receive do: (:release -> :ok)
    end
  end

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
