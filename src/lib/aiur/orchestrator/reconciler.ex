defmodule Aiur.Orchestrator.Reconciler do
  @moduledoc """
  Per-poll reconciliation of running entries against refreshed tracker states.
  All functions execute inside the orchestrator GenServer process.
  """

  require Logger

  alias Aiur.{Issue, Tracker}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{DispatchPolicy, PauseResume, RateLimitFallback, State}

  @spec reconcile_running_lifecycle(State.t()) :: State.t()
  def reconcile_running_lifecycle(%State{} = state) do
    state = Orchestrator.reconcile_stalled_running_issues(state)
    state = Orchestrator.reconcile_overrunning_agents(state)
    state = Orchestrator.reconcile_pending_auto_resumes(state)
    RateLimitFallback.reconcile(state)
  end

  @spec refresh_running_issue_states(State.t()) :: State.t()
  def refresh_running_issue_states(%State{} = state) do
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            DispatchPolicy.active_state_set(),
            DispatchPolicy.terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t()) :: State.t()
  def reconcile_running_issue_states(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(
      issues,
      state,
      DispatchPolicy.active_state_set(),
      DispatchPolicy.terminal_state_set()
    )
  end

  @spec reconcile_running_issue_states([Issue.t()], State.t(), MapSet.t(), MapSet.t()) :: State.t()
  def reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  def reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  @spec reconcile_issue_state(Issue.t() | term(), State.t(), MapSet.t(), MapSet.t()) :: State.t()
  def reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{State.issue_context(issue)} state=#{issue.state}; stopping active agent")

        Orchestrator.terminate_running_issue(state, issue.id, true)

      !DispatchPolicy.issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{State.issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        Orchestrator.terminate_running_issue(state, issue.id, false)

      Issue.paused?(issue) ->
        PauseResume.pause_issue_for_label_override(state, issue)

      DispatchPolicy.active_issue_state?(issue.state, active_states) ->
        maybe_reactivate_or_refresh(state, issue)

      Orchestrator.ci_wait_state?(issue.state) ->
        Orchestrator.pause_issue_for_ci_wait(state, issue)

      Orchestrator.human_review_state?(issue.state) ->
        Orchestrator.maybe_deactivate_human_review_issue(state, issue)

      Orchestrator.error_issue_state?(issue.state) ->
        Orchestrator.preserve_running_issue_on_external_error(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{State.issue_context(issue)} state=#{issue.state}; stopping active agent")

        Orchestrator.terminate_running_issue(state, issue.id, false)
    end
  end

  def reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  @spec maybe_reactivate_or_refresh(State.t(), Issue.t()) :: State.t()
  def maybe_reactivate_or_refresh(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{control: %{status: :deactivated}} = running_entry ->
        # Update the stored issue first so the dispatched agent sees
        # the freshest label state.
        new_entry = Map.put(running_entry, :issue, issue)
        state = %{state | running: Map.put(state.running, issue.id, new_entry)}

        case Orchestrator.reactivate_issue(state, new_entry) do
          {{:ok, :reactivated}, next_state} -> next_state
          {{:error, _reason}, next_state} -> next_state
        end

      %{control: %{status: :paused}, paused_reason: pause_reason} = running_entry
      when pause_reason in [:ci_wait, :label_override] ->
        new_entry = Map.put(running_entry, :issue, issue)
        state = %{state | running: Map.put(state.running, issue.id, new_entry)}

        state =
          if pause_reason == :ci_wait,
            do: Orchestrator.cancel_ci_wait_rewake(state, issue.id),
            else: state

        case Orchestrator.resume_paused_issue(state, new_entry, false) do
          {{:ok, :resumed}, next_state} ->
            next_state

          {{:error, reason}, next_state} ->
            Logger.info("Paused issue resume deferred: #{State.issue_context(issue)} reason=#{inspect(reason)}")
            next_state
        end

      _ ->
        refresh_running_issue_state(state, issue)
    end
  end

  @spec reconcile_missing_running_issue_ids(State.t(), [String.t()], [Issue.t() | term()]) :: State.t()
  def reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
      when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        Orchestrator.terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  def reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  @spec refresh_running_issue_state(State.t(), Issue.t()) :: State.t()
  def refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  @spec refresh_running_entry_issue(State.t(), Issue.t(), map()) :: State.t()
  def refresh_running_entry_issue(%State{} = state, %Issue{} = issue, running_entry)
      when is_map(running_entry) do
    %{state | running: Map.put(state.running, issue.id, Map.put(running_entry, :issue, issue))}
  end

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok
end
