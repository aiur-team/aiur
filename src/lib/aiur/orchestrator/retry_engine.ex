defmodule Aiur.Orchestrator.RetryEngine do
  @moduledoc """
  Retry scheduling and budget semantics for agent dispatch failures.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.AgentTeardown
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.RetryEngine.AgentDown
  alias Aiur.Orchestrator.RetryEngine.Exhaustion
  alias Aiur.Orchestrator.RetryEngine.HoldStreak
  alias Aiur.Orchestrator.RetryEngine.Lookup
  alias Aiur.Orchestrator.RetryEngine.PollFailure
  alias Aiur.Orchestrator.RetryEngine.Scheduling
  alias Aiur.Orchestrator.RetryEngine.WorkspaceWait
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.StatusReport

  @spec handle_retry_message(State.t(), String.t(), reference()) :: {:noreply, State.t()}
  def handle_retry_message(%State{} = state, issue_id, retry_token) do
    result =
      case Scheduling.pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, next_state} ->
          Lookup.handle_retry_issue(next_state, issue_id, attempt, metadata)

        :missing ->
          {:noreply, state}
      end

    publish_final_retry_state(result)
  end

  @doc false
  @spec publish_final_retry_state({:noreply, State.t()}) :: {:noreply, State.t()}
  def publish_final_retry_state({:noreply, final_state} = result) do
    StatusReport.notify_dashboard(final_state)
    result
  end

  @doc false
  @spec preserve_running_issue_on_external_error(State.t(), Issue.t()) :: State.t()
  def preserve_running_issue_on_external_error(%State{} = state, %Issue{} = issue) do
    previous_state =
      case Map.get(state.running, issue.id) do
        %{issue: %Issue{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        %{issue: %{state: state_name}} -> DispatchPolicy.normalize_issue_state(state_name)
        _ -> ""
      end

    if previous_state == "error" do
      Logger.debug("Issue remains in error state while agent is still active: #{State.issue_context(issue)}")
    else
      Logger.warning("Issue reported error state while agent is still active; preserving runner pending local completion: #{State.issue_context(issue)} state=#{issue.state}")
    end

    Reconciler.refresh_running_issue_state(state, issue)
  end

  @spec complete_issue(State.t(), String.t()) :: State.t()
  def complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
    |> AgentTeardown.clear_transient_reason_labels(issue_id)
  end

  @spec release_issue_claim(State.t(), String.t()) :: State.t()
  def release_issue_claim(%State{} = state, issue_id) do
    HoldStreak.clear(%{state | claimed: MapSet.delete(state.claimed, issue_id)}, issue_id)
  end

  @spec clear_budget_hold_streak(State.t(), String.t()) :: State.t()
  defdelegate clear_budget_hold_streak(state, issue_id), to: HoldStreak, as: :clear

  @spec handle_agent_down(State.t(), reference(), term()) :: {:noreply, State.t()}
  defdelegate handle_agent_down(state, ref, reason), to: AgentDown

  @spec prior_work_for_retry?(map(), boolean()) :: boolean()
  defdelegate prior_work_for_retry?(running_entry, continuation_enabled? \\ Config.agent_prior_work_continuation?()), to: AgentDown

  @doc false
  @spec wait_for_workspace_ownership(State.t(), String.t(), String.t(), term(), term(), map()) :: State.t()
  defdelegate wait_for_workspace_ownership(state, issue_id, identifier, owner, wait, retry_defaults \\ %{}), to: WorkspaceWait

  @doc false
  @spec release_workspace_wait(State.t(), String.t()) :: State.t()
  defdelegate release_workspace_wait(state, identifier), to: WorkspaceWait

  @doc false
  @spec release_workspace_wait(State.t(), String.t(), pid(), pos_integer()) :: State.t()
  defdelegate release_workspace_wait(state, identifier, guardian, generation), to: WorkspaceWait

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  defdelegate schedule_issue_retry(state, issue_id, attempt, metadata), to: Scheduling

  @spec failure_retry?(map()) :: boolean()
  defdelegate failure_retry?(metadata), to: Scheduling

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, integer(), map(), State.t()} | :missing
  defdelegate pop_retry_attempt_state(state, issue_id, retry_token), to: Scheduling

  @spec retry_delay(integer(), map()) :: non_neg_integer()
  defdelegate retry_delay(attempt, metadata), to: Scheduling

  @spec failure_retry_delay(integer()) :: non_neg_integer()
  defdelegate failure_retry_delay(attempt), to: Scheduling

  @spec normalize_retry_attempt(integer() | term()) :: non_neg_integer()
  defdelegate normalize_retry_attempt(attempt), to: Scheduling

  @spec next_retry_attempt_from_running(map()) :: pos_integer() | nil
  defdelegate next_retry_attempt_from_running(running_entry), to: Scheduling

  @doc false
  @spec move_exhausted_issue_to_error_state(String.t(), String.t(), term()) ::
          :ok | :alert_emitted | {:error, {:no_state_label_written, String.t()}}
  defdelegate move_exhausted_issue_to_error_state(issue_id, identifier, exhaustion_reason), to: Exhaustion

  @doc false
  @spec maybe_schedule_transient_auto_resume(State.t(), String.t(), term()) :: State.t()
  defdelegate maybe_schedule_transient_auto_resume(state, issue_id, reason), to: Exhaustion

  @doc false
  @spec record_claim_release(State.t(), String.t(), term()) :: State.t()
  defdelegate record_claim_release(state, issue_id, reason), to: PollFailure

  @doc false
  @spec format_retry_preflight_error(term()) :: String.t()
  defdelegate format_retry_preflight_error(reason), to: PollFailure

  @doc false
  @spec handle_retry_poll_failure(State.t(), String.t(), integer(), map(), term()) :: State.t()
  defdelegate handle_retry_poll_failure(state, issue_id, attempt, metadata, reason), to: PollFailure

  @spec handle_retry_issue(State.t(), String.t(), integer(), map(), keyword()) :: {:noreply, State.t()}
  defdelegate handle_retry_issue(state, issue_id, attempt, metadata, opts \\ []), to: Lookup

  @doc false
  @spec fetch_retry_issue(
          [term()],
          String.t(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()})
        ) :: {:ok, Issue.t() | nil} | {:error, term()}
  defdelegate fetch_retry_issue(candidate_issues, issue_id, fetch_issue_states_by_ids_fun), to: Lookup

  @doc false
  @spec handle_retry_issue_lookup(
          Issue.t() | nil,
          State.t(),
          String.t(),
          integer(),
          map(),
          keyword()
        ) ::
          {:noreply, State.t()}
  defdelegate handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata, opts \\ []), to: Lookup

  @doc false
  @spec ensure_active_retry_started(State.t(), Issue.t(), pos_integer() | nil, map(), keyword()) :: State.t()
  defdelegate ensure_active_retry_started(state, issue, attempt, metadata, opts), to: Lookup
end
