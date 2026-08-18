defmodule Aiur.DecisionDispatchTasksLifecycleTest do
  use ExUnit.Case, async: true

  import Aiur.DecisionDispatchTestSupport

  alias Aiur.DecisionDispatchTasks

  test "a normal result emits exactly one correlated callback" do
    name = unique_name(__MODULE__, "Result")
    start_supervised!({DecisionDispatchTasks, name: name})

    assert :pending =
             DecisionDispatchTasks.enqueue(
               "AIUR-1",
               %{attempt_id: "attempt-1"},
               fn -> {:ok, :accepted} end,
               callback(self()),
               name
             )

    assert_receive {:terminal, %{attempt_id: "attempt-1"}, {:ok, :accepted}}, 2_000
    refute_receive {:terminal, %{attempt_id: "attempt-1"}, _result}, 100
  end

  test "an abnormal worker exit emits once and releases the ticket lane" do
    name = unique_name(__MODULE__, "Down")
    coordinator = start_supervised!({DecisionDispatchTasks, name: name})
    callback = callback(self())

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :killed, blocking_job(self(), :killed), callback, name)

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-1", :after_kill, fn -> :ok end, callback, name)
    assert_receive {:started, :killed, worker}, 2_000
    Process.exit(worker, :kill)

    assert_receive {:terminal, :killed, {:error, {:decision_dispatch_task_exit, :killed}}}, 2_000
    assert_receive {:terminal, :after_kill, :ok}, 2_000
    refute_receive {:terminal, :killed, _result}, 100
    assert Process.alive?(coordinator)
  end

  test "timeout terminates the worker and ignores its actual late terminal messages" do
    name = unique_name(__MODULE__, "Timeout")
    start_supervised!({DecisionDispatchTasks, name: name, operation_timeout_ms: 20})
    callback = callback(self())

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :timed_out, blocking_job(self(), :timed_out), callback, name)

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-1", :after_timeout, fn -> :ok end, callback, name)
    assert_receive {:started, :timed_out, worker}, 2_000
    task_ref = :sys.get_state(name).active["AIUR-1"].ref
    worker_ref = Process.monitor(worker)

    assert_receive {:terminal, :timed_out, {:error, :decision_dispatch_timeout}}, 2_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
    assert_receive {:terminal, :after_timeout, :ok}, 2_000

    send(name, {task_ref, :late})
    send(name, {:decision_dispatch_timeout, task_ref})
    _state = :sys.get_state(name)
    refute_receive {:terminal, :timed_out, _result}, 100
  end

  test "task-start failure is terminal immediately and does not block later work" do
    name = unique_name(__MODULE__, "StartFailure")
    {:ok, starts} = Agent.start_link(fn -> 0 end)

    task_starter = fn operation ->
      attempt = Agent.get_and_update(starts, fn count -> {count + 1, count + 1} end)

      if attempt == 1,
        do: {:error, :task_supervisor_unavailable},
        else: {:ok, Task.Supervisor.async(Aiur.TaskSupervisor, operation)}
    end

    start_supervised!({DecisionDispatchTasks, name: name, task_starter: task_starter})

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :failed_start, fn -> :never end, callback(self()), name)

    assert_receive {:terminal, :failed_start, {:error, {:decision_dispatch_task_start_failed, :task_supervisor_unavailable}}},
                   2_000

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-1", :next, fn -> :ok end, callback(self()), name)
    assert_receive {:terminal, :next, :ok}, 2_000
    assert Agent.get(starts, & &1) == 2
  end

  test "coordinator exit terminates its active dispatch workers" do
    name = unique_name(__MODULE__, "CoordinatorExit")
    coordinator = start_supervised!({DecisionDispatchTasks, name: name})

    assert :pending =
             DecisionDispatchTasks.enqueue("AIUR-1", :active, blocking_job(self(), :active), callback(self()), name)

    assert_receive {:started, :active, worker}, 2_000
    worker_ref = Process.monitor(worker)
    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000
    refute_receive {:terminal, :active, _result}, 100
  end

  test "owner exit purges active and queued work before replacement admission" do
    name = unique_name(__MODULE__, "OwnerExit")
    start_supervised!({DecisionDispatchTasks, name: name})
    parent = self()

    owner =
      spawn(fn ->
        callback = callback(parent)
        :pending = DecisionDispatchTasks.enqueue("AIUR-1", :active, blocking_job(parent, :active), callback, name)
        :pending = DecisionDispatchTasks.enqueue("AIUR-1", :queued, fn -> :old_queued end, callback, name)
        send(parent, :owner_admitted)
        receive do: (:stop -> :ok)
      end)

    assert_receive :owner_admitted, 2_000
    assert_receive {:started, :active, worker}, 2_000
    worker_ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    assert :pending = DecisionDispatchTasks.enqueue("AIUR-1", :replacement, fn -> :new end, callback(self()), name)
    assert_receive {:terminal, :replacement, :new}, 2_000
    refute_receive {:terminal, :active, _result}, 100
    refute_receive {:terminal, :queued, _result}, 100
  end
end
