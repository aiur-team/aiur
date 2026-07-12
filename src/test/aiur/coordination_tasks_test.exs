defmodule Aiur.CoordinationTasksTest do
  use ExUnit.Case, async: true

  alias Aiur.CoordinationTasks

  test "enqueue returns pending while admitted work is blocked" do
    name = Module.concat(__MODULE__, "Queue#{System.unique_integer([:positive])}")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    operation = fn ->
      send(test_pid, {:started, self()})

      receive do
        :release -> send(test_pid, :finished)
      end
    end

    assert :pending = CoordinationTasks.enqueue(operation, name)
    assert_receive {:started, task}, 200
    refute_receive :finished, 20

    send(task, :release)
    assert_receive :finished, 200
  end

  test "operations retain admission order" do
    name = Module.concat(__MODULE__, "Ordered#{System.unique_integer([:positive])}")
    start_supervised!({CoordinationTasks, name: name})
    test_pid = self()

    assert :pending =
             CoordinationTasks.enqueue(
               fn ->
                 send(test_pid, {:first_started, self()})
                 receive do: (:release -> send(test_pid, :first_finished))
               end,
               name
             )

    assert :pending = CoordinationTasks.enqueue(fn -> send(test_pid, :second_started) end, name)
    assert_receive {:first_started, first}, 200
    refute_receive :second_started, 20
    send(first, :release)
    assert_receive :first_finished, 200
    assert_receive :second_started, 200
  end

  test "a timed out operation does not starve the queue" do
    name = Module.concat(__MODULE__, "Timeout#{System.unique_integer([:positive])}")
    start_supervised!({CoordinationTasks, name: name, timeout_ms: 20})
    test_pid = self()

    assert :pending = CoordinationTasks.enqueue(fn -> Process.sleep(:infinity) end, name)
    assert :pending = CoordinationTasks.enqueue(fn -> send(test_pid, :after_timeout) end, name)

    assert_receive :after_timeout, 200
  end
end
