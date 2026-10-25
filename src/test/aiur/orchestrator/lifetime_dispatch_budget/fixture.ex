defmodule Aiur.LifetimeDispatchBudgetCase do
  @moduledoc false

  use ExUnit.CaseTemplate
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Workflow

  @issue_id "issue-lifetime"
  @window_ms 60 * 1_000

  setup %{config: config} do
    previous = Application.get_env(:aiur, :workflow_file_path)
    previous_store = Application.get_env(:aiur, :dispatch_budget_store_path)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_log_file = Application.get_env(:aiur, :log_file)
    dir = Aiur.TestSupport.tmp_root!("aiur-lifetime")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.yaml")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)
    Application.delete_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :decision_state_dir, Path.join(dir, "stable-state"))
    Application.put_env(:aiur, :log_file, Path.join([dir, "session-one", "aiur.log"]))
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(Path.join(dir, "stable-state"))

    on_exit(fn ->
      if is_nil(previous) do
        Workflow.clear_workflow_file_path()
      else
        Workflow.set_workflow_file_path(previous)
      end

      if is_nil(previous_store) do
        Application.delete_env(:aiur, :dispatch_budget_store_path)
      else
        Application.put_env(:aiur, :dispatch_budget_store_path, previous_store)
      end

      if is_nil(previous_state_dir) do
        Application.delete_env(:aiur, :decision_state_dir)
      else
        Application.put_env(:aiur, :decision_state_dir, previous_state_dir)
      end

      if is_nil(previous_log_file) do
        Application.delete_env(:aiur, :log_file)
      else
        Application.put_env(:aiur, :log_file, previous_log_file)
      end
    end)

    :ok
  end

  def run(state, now_ms), do: Dispatcher.check_thrash_budget(state, @issue_id, now_ms)

  def commit(state), do: Dispatcher.record_dispatch_committed(state, @issue_id)

  def thrash_budget(state), do: state.dispatch_recovery.codex_thrash_budget

  def with_thrash_budget(state, budget), do: put_in(state.dispatch_recovery.codex_thrash_budget, budget)

  # A committed dispatch = the gate passes (window) + the runner survives
  # provisioning (lifetime commit). Each sits in its own lapsed window, so the
  # per-window breaker never trips — exactly the #1091 shape (85 cold
  # dispatches, none circuit-broken) that the lifetime latch exists to bound.
  def dispatch_n(state, n) do
    Enum.reduce(1..n, state, fn i, acc ->
      {:ok, gated} = run(acc, i * (@window_ms + 1))
      commit(gated)
    end)
  end
end
