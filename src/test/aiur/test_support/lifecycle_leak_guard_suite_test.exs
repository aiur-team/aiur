defmodule Aiur.TestSupport.LifecycleLeakGuardSuiteTest do
  use Aiur.TestSupport

  require Logger

  alias Aiur.TestSupport.LifecycleLeakGuard

  test "late tool executor warning is attributed to its starting test" do
    previous_mode = System.get_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE")
    System.put_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE", "fail")

    on_exit(fn ->
      if previous_mode,
        do: System.put_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE", previous_mode),
        else: System.delete_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE")
    end)

    test_pid = self()

    {:ok, worker} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        Process.put(:"$initial_call", {Aiur.AgentRunner.ToolExecutor, :execute, 1})
        Process.put(:"$callers", [test_pid])
        send(test_pid, {:worker_ready, self()})

        receive do
          :emit_late_log -> Logger.warning("tool executor completed after teardown")
        end
      end)

    receive do
      {:worker_ready, ^worker} -> :ok
    end

    LifecycleLeakGuard.finish(test_pid)
    monitor = Process.monitor(worker)
    send(worker, :emit_late_log)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000

    assert_raise RuntimeError, ~r/lifecycle event late log/, fn -> LifecycleLeakGuard.check!() end
  end

  test "report mode records a late tool executor warning without killing the process" do
    previous_mode = System.get_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE")
    System.delete_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE")

    on_exit(fn ->
      if previous_mode,
        do: System.put_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE", previous_mode),
        else: System.delete_env("AIUR_LIFECYCLE_LEAK_GUARD_MODE")
    end)

    test_pid = self()

    {:ok, worker} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        Process.put(:"$initial_call", {Aiur.AgentRunner.ToolExecutor, :execute, 1})
        Process.put(:"$callers", [test_pid])
        send(test_pid, {:worker_ready, self()})

        receive do
          :emit_late_log ->
            Logger.warning("tool executor completed after teardown")
            send(test_pid, {:worker_finished, self()})

            receive do
              :stop -> :ok
            end
        end
      end)

    assert_receive {:worker_ready, ^worker}, 1_000
    LifecycleLeakGuard.finish(test_pid)
    send(worker, :emit_late_log)
    assert_receive {:worker_finished, ^worker}, 1_000
    assert Process.alive?(worker)
    assert :ok = LifecycleLeakGuard.check!()
    monitor = Process.monitor(worker)
    send(worker, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end
end
