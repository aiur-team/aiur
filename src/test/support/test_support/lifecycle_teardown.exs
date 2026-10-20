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

    Aiur.TestSupport.quiesce_live_orchestrator()
    Aiur.TestSupport.restore_app_env(previous_app_env)
    Application.delete_env(:aiur, :server_port_override)
    Application.delete_env(:aiur, :memory_tracker_issues)
    Application.delete_env(:aiur, :memory_tracker_recipient)
    EventsPublisher.set_tracked_fn(fn _ -> true end)
    EventsSubscriptionStore.set_enqueue_fn(nil)
    Aiur.TestCleanup.rm_rf!(workflow_root)
    Aiur.TestScopeGuard.restore(previous_test_scope_state)
    OrchestratorGuard.restore_codeowners_baseline!()

    # Reload onto the restored config and recover the app after a sibling test
    # toppled it while this case's config was transiently active.
    if Process.whereis(Aiur.WorkflowStore) do
      try do
        Aiur.WorkflowStore.force_reload()
      catch
        :exit, _ -> :ok
      end
    end

    unless Process.whereis(Aiur.Supervisor), do: Application.ensure_all_started(:aiur)

    Aiur.TestSupport.verify_restored_shared_state!(
      previous_app_env,
      Map.fetch!(previous_test_scope_state.env, "AIUR_INSTANCE_KEY"),
      context
    )

    LifecycleLeakGuard.finish!(lifecycle_test_pid, scope_state_violation, runner_leaks)
  end

  @doc false
  @spec capture_and_stop_test_runners(pid(), MapSet.t(pid())) :: [{pid(), String.t()}]
  def capture_and_stop_test_runners(test_pid, runner_tasks_before) do
    runner_leaks = LifecycleLeakGuard.live_runners(test_pid)
    RunnerTasks.stop_started_since(runner_tasks_before)
    runner_leaks
  end
end
