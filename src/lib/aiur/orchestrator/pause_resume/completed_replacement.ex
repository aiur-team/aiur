defmodule Aiur.Orchestrator.PauseResume.CompletedReplacement do
  @moduledoc """
  Replaces a completed runner with a fresh dispatch after revalidating the issue.
  """

  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PauseResume.TrackerControl
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  require Logger

  @doc false
  @spec replace_completed_issue(State.t(), map(), Issue.t()) :: State.t()
  def replace_completed_issue(%State{} = state, running_entry, %Issue{} = issue) do
    if State.completed_provenance?(running_entry) do
      revalidate_completed_replacement(state, running_entry, issue)
    else
      state
    end
  end

  defp normalize_completed_entry(running_entry, issue) do
    running_entry
    |> Map.put(:issue, issue)
    |> Map.put(:completed_provenance, true)
    |> Map.delete(:paused_reason)
    |> put_in([:control, :status], :completed)
  end

  defp revalidate_completed_replacement(state, running_entry, issue) do
    {_reply, next} =
      Resume.run_running_effect(state, running_entry, :completed_revalidation, fn -> TrackerControl.perform_tracker_io(:revalidate_completed, [issue]) end, fn current, entry, result ->
        next =
          case result do
            {:ok, refreshed_issue} ->
              dispatch_completed_replacement(current, entry, refreshed_issue)

            {:skip, %Issue{} = refreshed_issue} ->
              Reconciler.refresh_running_entry_issue(current, refreshed_issue, entry)

            {:skip, :missing} ->
              current

            {:error, reason} ->
              Logger.warning("Completed runner replacement skipped; issue refresh failed: #{State.issue_context(issue)} reason=#{inspect(reason)}")
              current
          end

        {{:ok, :pending}, next}
      end)

    next
  end

  @doc false
  @spec dispatch_completed_replacement(State.t(), map(), Issue.t(), keyword()) :: State.t()
  def dispatch_completed_replacement(state, running_entry, issue, opts \\ []) do
    {_result, state} = dispatch_completed_replacement_result(state, running_entry, issue, opts)
    state
  end

  @doc false
  @spec dispatch_completed_replacement_result(State.t(), map(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, {:redispatch_deferred, term()}}, State.t()}
  def dispatch_completed_replacement_result(state, running_entry, issue, opts \\ []) do
    running_entry = normalize_completed_entry(running_entry, issue)

    state =
      state
      |> Map.update!(:running, &Map.put(&1, issue.id, running_entry))
      |> CiLifecycle.cancel_ci_wait_rewake(issue.id)

    worker_host = Map.get(running_entry, :worker_host)

    if Slots.dispatch_slots_available?(issue, state) do
      dispatch_admitted_completed_replacement(state, running_entry, issue, worker_host, opts)
    else
      {{:error, {:redispatch_deferred, :max_concurrent_agents_reached}}, state}
    end
  end

  defp dispatch_admitted_completed_replacement(state, running_entry, issue, worker_host, opts) do
    admit = Keyword.get(opts, :admit_fun, &Dispatcher.admit_redispatch/3)
    replace = Keyword.get(opts, :replace_fun, &replace_completed_entry/4)

    case admit.(state, issue, worker_host) do
      {:ok, admitted_state} ->
        classify_completed_replacement(replace.(admitted_state, running_entry, issue, worker_host), issue)

      {:error, reason, rejected_state} ->
        {{:error, {:redispatch_deferred, reason}}, rejected_state}
    end
  end

  defp classify_completed_replacement({result, %State{} = state}, _issue), do: {result, state}

  defp classify_completed_replacement(%State{} = state, issue) do
    cond do
      live_replacement?(state, issue.id) -> {{:ok, :started}, state}
      TrackerTasks.issue_pending?(state, issue.id) -> {{:ok, :pending}, state}
      true -> {{:error, {:redispatch_deferred, redispatch_start_failure_reason(state, issue)}}, state}
    end
  end

  defp redispatch_start_failure_reason(state, issue) do
    case Map.fetch(state.retry_attempts, issue.id) do
      {:ok, reason} -> {:worker_start_failed, reason}
      :error -> :cause_unknown
    end
  end

  # This is the single funnel every recycle re-dispatch goes through: the runner
  # reached its completed boundary (max_turns, or a replacement) while the issue
  # was still active, so the ticket already has a branch, workspace, and workpad.
  # Flag it as prior work so a thread that cannot be resumed continues from that
  # handoff instead of cold-starting brainstorm/plan over existing work.
  defp replace_completed_entry(state, running_entry, issue, worker_host) do
    prior_work? = Config.agent_prior_work_continuation?()

    replace_admitted_completed_entry_result(
      state,
      running_entry,
      issue,
      worker_host,
      fn dispatch_state, dispatch_issue, attempt, host ->
        Dispatcher.do_dispatch_issue(dispatch_state, dispatch_issue, attempt, host, prior_work: prior_work?)
      end
    )
  end

  @doc false
  @spec replace_admitted_completed_entry(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          State.t()
  def replace_admitted_completed_entry(
        state,
        running_entry,
        issue,
        worker_host,
        dispatch_fun
      )
      when is_function(dispatch_fun, 4) do
    {_result, state} =
      replace_admitted_completed_entry_result(state, running_entry, issue, worker_host, dispatch_fun)

    state
  end

  @doc false
  @spec replace_admitted_completed_entry_result(State.t(), map(), Issue.t(), String.t() | nil, function()) ::
          {{:ok, :started} | {:error, {:redispatch_deferred, term()}}, State.t()}
  def replace_admitted_completed_entry_result(
        state,
        running_entry,
        issue,
        worker_host,
        dispatch_fun
      )
      when is_function(dispatch_fun, 4) do
    issue_id = issue.id

    Logger.info("Replacing completed runner: issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

    _ = Aiur.PauseContainment.release_target(issue.identifier || issue.id)

    next_state =
      state
      |> AgentTeardown.terminate_running_issue(issue_id, false)
      |> dispatch_fun.(issue, nil, worker_host)

    cond do
      live_replacement?(next_state, issue_id) ->
        {{:ok, :started}, next_state}

      TrackerTasks.issue_pending?(next_state, issue_id) ->
        {{:ok, :pending}, next_state}

      true ->
        reason = redispatch_start_failure_reason(next_state, issue)
        {{:error, {:redispatch_deferred, reason}}, restore_completed_entry(next_state, running_entry, issue)}
    end
  end

  defp live_replacement?(state, issue_id) do
    case Map.get(state.running, issue_id) do
      %{pid: pid, ref: ref, control: %{status: :working}} ->
        is_pid(pid) and Process.alive?(pid) and is_reference(ref)

      _ ->
        false
    end
  end

  defp restore_completed_entry(state, running_entry, issue) do
    issue_id = issue.id

    completed_entry =
      running_entry
      |> Map.put(:issue, issue)
      |> Map.put(:pid, nil)
      |> Map.put(:ref, nil)
      |> Map.put(:completed_provenance, true)
      |> Map.put(:completion_totals_recorded, true)
      |> put_in([:control, :status], :completed)

    %{
      state
      | running: Map.put(state.running, issue_id, completed_entry),
        claimed: MapSet.put(state.claimed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp restart_completed_issue(state, running_entry) do
    issue = Map.fetch!(running_entry, :issue)
    Resume.run_running_effect(state, running_entry, :completed_restart, fn -> TrackerControl.perform_tracker_io(:revalidate_completed, [issue]) end, &restart_revalidated_completed_issue/3)
  end

  @doc false
  @spec restart_revalidated_completed_issue(State.t(), term(), term()) :: term()
  def restart_revalidated_completed_issue(state, running_entry, result) do
    case result do
      {:ok, refreshed_issue} ->
        dispatch_completed_replacement_result(state, running_entry, refreshed_issue)

      {:skip, %Issue{} = refreshed_issue} ->
        reason =
          case DispatchPolicy.dispatch_decision(refreshed_issue, state) do
            {:skip, detail} -> {:not_dispatchable, detail}
            :dispatch -> :stale_after_revalidation
          end

        next_state = Reconciler.refresh_running_entry_issue(state, refreshed_issue, running_entry)
        {{:error, {:redispatch_deferred, reason}}, next_state}

      {:skip, :missing} ->
        {{:error, {:redispatch_deferred, :missing_after_revalidation}}, state}

      {:error, reason} ->
        {{:error, {:redispatch_deferred, {:tracker_revalidation_failed, reason}}}, state}
    end
  end

  @doc false
  @spec restart_completed_provenance_issue(State.t(), term()) :: term()
  def restart_completed_provenance_issue(state, running_entry),
    do: restart_completed_issue(state, running_entry)
end
