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

  test "teardown restores app env and test scope when quiesce exits" do
    previous_app_env = Aiur.TestSupport.capture_app_env()
    previous_scope = Aiur.TestScopeGuard.capture()
    expected_scope = Map.update!(previous_scope, :env, &Map.put(&1, "AIUR_DEV_TEST_STATE_DIR", "expected-test-state"))
    context = %{async: false}
    root = Path.join(System.tmp_dir!(), "lifecycle-teardown-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    Application.put_env(:aiur, :runtime_state_dir, "temporary-runtime-state")
    System.put_env("AIUR_DEV_TEST_STATE_DIR", "temporary-test-state")

    try do
      assert_raise RuntimeError, ~r/test scope state leaked/, fn ->
        LifecycleTeardown.teardown_test_scope!(root, Aiur.TestSupport.capture_runner_tasks(), self(), expected_scope, previous_app_env, previous_scope, context)
      end
    after
      Aiur.TestScopeGuard.restore(previous_scope)
    end

    assert Application.fetch_env(:aiur, :runtime_state_dir) == Keyword.fetch!(previous_app_env, :runtime_state_dir)
    assert System.get_env("AIUR_DEV_TEST_STATE_DIR") == Map.fetch!(previous_scope.env, "AIUR_DEV_TEST_STATE_DIR")
    refute File.exists?(root)
  end
end
