defmodule Aiur.Orchestrator.AutoResumeTestSupport do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Aiur.{Issue, Workflow}
  alias Aiur.Orchestrator.{AutoResume, State}

  @issue_id "issue-transient"
  @enabled """
  tracker:
    kind: memory
    active_states:
      - todo
      - in-progress
      - rework
    terminal_states:
      - done
  agent:
    kind: codex
    max_dispatches_per_ticket: 10
  """

  def enabled_config, do: @enabled

  def auto_resume_setup(attrs) do
    config = Map.get(attrs, :config, @enabled)
    previous_store = Application.get_env(:aiur, :dispatch_budget_store_path)
    previous_state_dir = Application.get_env(:aiur, :decision_state_dir)
    previous_log_file = Application.get_env(:aiur, :log_file)
    previous_workflow = Application.get_env(:aiur, :workflow_file_path)
    dir = Aiur.TestSupport.tmp_root!("aiur-auto-resume")
    File.mkdir_p!(dir)
    path = Path.join(dir, "config.yaml")
    File.write!(path, config)
    Workflow.set_workflow_file_path(path)
    Application.delete_env(:aiur, :dispatch_budget_store_path)
    Application.put_env(:aiur, :decision_state_dir, Path.join(dir, "stable-state"))
    Application.put_env(:aiur, :log_file, Path.join([dir, "session-one", "aiur.log"]))

    on_exit(fn ->
      if previous_workflow, do: Workflow.set_workflow_file_path(previous_workflow), else: Workflow.clear_workflow_file_path()

      if previous_store,
        do: Application.put_env(:aiur, :dispatch_budget_store_path, previous_store),
        else: Application.delete_env(:aiur, :dispatch_budget_store_path)

      if is_nil(previous_state_dir) do
        Application.delete_env(:aiur, :decision_state_dir)
      else
        Application.put_env(:aiur, :decision_state_dir, previous_state_dir)
      end

      if previous_log_file,
        do: Application.put_env(:aiur, :log_file, previous_log_file),
        else: Application.delete_env(:aiur, :log_file)

      Aiur.TestCleanup.rm_rf!(dir)
    end)

    :ok
  end

  def issue(overrides \\ %{}) do
    struct!(
      Issue,
      Map.merge(
        %{id: @issue_id, identifier: "repo#transient", title: "transient", state: "error", labels: []},
        overrides
      )
    )
  end

  def state_with(%{last_polled_issues: issues, auto_resume: auto_resume}) do
    %State{last_polled_issues: Map.new(issues, &{&1.id, &1}), auto_resume: auto_resume}
  end

  def due_state(issue, attempt \\ 1) do
    scheduled_at = System.monotonic_time(:millisecond) - AutoResume.backoff_ms(attempt) - 1_000
    state_with(%{last_polled_issues: [issue], auto_resume: %{issue.id => %{attempt: attempt, cause: :transient_tracker, scheduled_at_ms: scheduled_at}}})
  end

  def claim_fun(state, issue) do
    %{state | claimed: MapSet.put(state.claimed, issue.id)}
  end

  # Tests that exercise the dispatch path inject a permissive admission gate so
  # the result does not depend on the host's live load/FD sample; the real gate
  # (`Dispatcher.auto_resume_admission/1`) is unit-tested separately and the
  # hold-deferral behaviour is covered by the injected-hold tests below.
  def admit, do: fn _state -> :dispatch end
end
