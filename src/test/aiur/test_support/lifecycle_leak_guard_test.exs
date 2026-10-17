defmodule Aiur.TestSupport.LifecycleLeakGuardTest do
  # Not async: the guard tables are suite-wide.
  use Aiur.TestSupport

  alias Aiur.TestSupport.LifecycleLeakGuard

  test "teardown fails the test that leaves a dispatched runner alive" do
    previous_signal = Application.get_env(:aiur, :signal)
    Application.put_env(:aiur, :signal, lifecycle_sink: LifecycleLeakGuard)

    on_exit(fn -> Application.put_env(:aiur, :signal, previous_signal) end)

    owner = LifecycleLeakGuard.track(%{module: __MODULE__, test: :"teardown fails the test that leaves a dispatched runner alive"})

    runner =
      spawn(fn ->
        Process.put(:"$initial_call", {Aiur.Orchestrator.Dispatcher.Launch, :"-start_runner_task/5-fun-0-", 0})
        Process.put(:"$callers", [owner])

        receive do
          :stop -> :ok
        end
      end)

    error = assert_raise RuntimeError, fn -> LifecycleLeakGuard.finish!(owner, nil) end
    assert error.message =~ "#{inspect(__MODULE__)} teardown fails the test that leaves a dispatched runner alive"
    assert error.message =~ inspect(runner)
    refute Process.alive?(runner)
  end
end
