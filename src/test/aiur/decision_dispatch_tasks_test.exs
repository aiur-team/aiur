defmodule Aiur.DecisionDispatchTasksTest do
  use ExUnit.Case, async: true

  import Aiur.DecisionDispatchTestSupport

  alias Aiur.DecisionDispatchTasks

  test "same-ticket jobs retain admission order while independent tickets run fairly" do
    name = unique_name(__MODULE__, "Ordered")
    start_supervised!({DecisionDispatchTasks, name: name, max_concurrency: 1})
    callback = callback(self())

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :first, blocking_job(self(), :first), callback, name)

    assert_receive {:started, :first, first}, 2_000

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :second, blocking_job(self(), :second), callback, name)

    assert :pending =
             DecisionDispatchTasks.enqueue(
               "AIUR-2",
               :independent,
               blocking_job(self(), :independent),
               callback,
               name
             )

    send(first, :release)
    assert_receive {:terminal, :first, :ok}, 2_000
    assert_receive {:started, :independent, independent}, 2_000
    refute_receive {:started, :second, _pid}, 0

    send(independent, :release)
    assert_receive {:terminal, :independent, :ok}, 2_000
    assert_receive {:started, :second, second}, 2_000
    send(second, :release)
    assert_receive {:terminal, :second, :ok}, 2_000
  end

  test "global and per-ticket pending bounds reject overload and recover" do
    name = unique_name(__MODULE__, "Bounded")

    start_supervised!({DecisionDispatchTasks, name: name, max_concurrency: 1, max_pending: 2, max_pending_per_ticket: 1, saturation_notifier: fn _transition -> :ok end})

    callback = callback(self())

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :active, blocking_job(self(), :active), callback, name)

    assert_receive {:started, :active, active}, 2_000
    assert :pending = DecisionDispatchTasks.enqueue("AIUR-1", :queued, fn -> :ok end, callback, name)

    assert {:error, :decision_dispatch_overloaded} =
             DecisionDispatchTasks.enqueue("AIUR-1", :per_ticket_full, fn -> :ok end, callback, name)

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-2", :independent, fn -> :ok end, callback, name)

    assert {:error, :decision_dispatch_overloaded} =
             DecisionDispatchTasks.enqueue("AIUR-3", :globally_full, fn -> :ok end, callback, name)

    send(active, :release)
    assert_receive {:terminal, :active, :ok}, 2_000
    assert_receive {:terminal, :independent, :ok}, 2_000
    assert_receive {:terminal, :queued, :ok}, 2_000

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-3", :recovered, fn -> :ok end, callback, name)
    assert_receive {:terminal, :recovered, :ok}, 2_000
  end

  test "global concurrency is a hard ceiling" do
    name = unique_name(__MODULE__, "Parallel")
    start_supervised!({DecisionDispatchTasks, name: name, max_concurrency: 2})
    callback = callback(self())

    for correlation <- [:one, :two, :three] do
      assert :pending =
               DecisionDispatchTasks.enqueue(
                 "AIUR-#{correlation}",
                 correlation,
                 blocking_job(self(), correlation),
                 callback,
                 name
               )
    end

    assert_receive {:started, :one, one}, 2_000
    assert_receive {:started, :two, two}, 2_000
    refute_receive {:started, :three, _pid}, 0

    send(one, :release)
    assert_receive {:started, :three, three}, 2_000
    send(two, :release)
    send(three, :release)
  end

  test "local admission waits for a definitive result without late acceptance" do
    name = unique_name(__MODULE__, "Admission")
    coordinator = start_supervised!({DecisionDispatchTasks, name: name})
    test_pid = self()
    :ok = :sys.suspend(coordinator)

    call =
      Task.async(fn ->
        DecisionDispatchTasks.enqueue(
          "AIUR-1",
          :accepted,
          fn -> :ok end,
          callback(test_pid),
          name,
          owner: test_pid
        )
      end)

    refute Task.yield(call, 30)
    :ok = :sys.resume(coordinator)
    assert :pending = Task.await(call, 2_000)
    assert_receive {:terminal, :accepted, :ok}, 2_000
  end
end
