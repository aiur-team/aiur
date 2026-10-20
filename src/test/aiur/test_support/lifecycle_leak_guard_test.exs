defmodule Aiur.TestSupport.LifecycleLeakGuardTest do
  # Not async: the guard tables are suite-wide.
  use Aiur.TestSupport

  alias Aiur.TestSupport.LifecycleLeakGuard
  alias Aiur.TestSupport.LifecycleTeardown

  test "teardown fails the test that leaves a dispatched runner alive" do
    previous_signal = Application.get_env(:aiur, :signal)
    Application.put_env(:aiur, :signal, lifecycle_sink: LifecycleLeakGuard)

    on_exit(fn -> Application.put_env(:aiur, :signal, previous_signal) end)

    owner = self()
    runners_before = Aiur.TestSupport.capture_runner_tasks()

    {:ok, runner} =
      Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
        Process.put(:"$initial_call", {Aiur.Orchestrator.Dispatcher.Launch, :"-start_runner_task/5-fun-0-", 0})

        receive do
          :stop -> :ok
        end
      end)

    runner_leaks = LifecycleTeardown.capture_and_stop_test_runners(owner, runners_before)
    assert Enum.map(runner_leaks, &elem(&1, 0)) == [runner]

    error = assert_raise RuntimeError, fn -> LifecycleLeakGuard.finish!(owner, nil, runner_leaks) end
    assert error.message =~ "#{inspect(__MODULE__)} test teardown fails the test that leaves a dispatched runner alive"
    assert error.message =~ inspect(runner)
    refute Process.alive?(runner)
  end
end
