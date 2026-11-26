defmodule Aiur.TestSupport.LifecycleTeardown do
  @moduledoc false

  alias Aiur.Events.Publisher, as: EventsPublisher
  alias Aiur.Events.SubscriptionStore, as: EventsSubscriptionStore
  alias Aiur.TestSupport.{LifecycleLeakGuard, OrchestratorGuard, RunnerTasks}

  @spec teardown_test_scope!(
          Path.t(),
          MapSet.t(pid()),
          pid(),
          map(),
          [{atom(), {:ok, term()} | :error}],
          map(),
          map()
        ) :: :ok
  def teardown_test_scope!(
        workflow_root,
        runner_tasks_before,
        lifecycle_test_pid,
        expected_test_scope_state,
        previous_app_env,
        previous_test_scope_state,
        context
      ) do
    scope_state_violation = Aiur.TestScopeGuard.violation(expected_test_scope_state)
    runner_leaks = capture_and_stop_test_runners(lifecycle_test_pid, runner_tasks_before)

    errors =
      run_cleanup_steps([
        fn -> Aiur.TestSupport.quiesce_live_orchestrator() end,
        fn -> Aiur.TestSupport.restore_app_env(previous_app_env) end,
        fn -> Application.delete_env(:aiur, :server_port_override) end,
        fn -> Application.delete_env(:aiur, :memory_tracker_issues) end,
        fn -> Application.delete_env(:aiur, :memory_tracker_recipient) end,
        fn -> EventsPublisher.set_tracked_fn(fn _ -> true end) end,
        fn -> EventsSubscriptionStore.set_enqueue_fn(nil) end,
        fn -> Aiur.TestCleanup.rm_rf!(workflow_root) end,
        fn -> Aiur.TestScopeGuard.restore(previous_test_scope_state) end,
        fn -> OrchestratorGuard.restore_codeowners_baseline!() end,
        fn -> reload_workflow_store() end,
        fn -> unless Process.whereis(Aiur.Supervisor), do: Application.ensure_all_started(:aiur) end,
        fn ->
          Aiur.TestSupport.verify_restored_shared_state!(
            previous_app_env,
            Map.fetch!(previous_test_scope_state.env, "AIUR_INSTANCE_KEY"),
            context
          )
        end,
        fn -> LifecycleLeakGuard.finish!(lifecycle_test_pid, scope_state_violation, runner_leaks) end
      ])

    case errors do
      [] -> :ok
      errors -> raise "test scope teardown failed: #{Enum.join(errors, "; ")}"
    end
  end

  @doc false
  @spec capture_and_stop_test_runners(pid(), MapSet.t(pid())) :: [{pid(), String.t()}]
  def capture_and_stop_test_runners(test_pid, runner_tasks_before) do
    runner_leaks = LifecycleLeakGuard.live_owned_processes(test_pid)
    LifecycleLeakGuard.stop_owned_processes(runner_leaks)
    RunnerTasks.stop_started_since(runner_tasks_before)
    runner_leaks
  end

  defp run_cleanup_steps(steps) do
    Enum.flat_map(steps, fn step ->
      try do
        step.()
        []
      rescue
        error -> [Exception.format(:error, error, __STACKTRACE__)]
      catch
        kind, reason -> [Exception.format(kind, reason, __STACKTRACE__)]
      end
    end)
  end

  defp reload_workflow_store do
    if Process.whereis(Aiur.WorkflowStore), do: Aiur.WorkflowStore.force_reload()
  catch
    :exit, _ -> :ok
  end
end
