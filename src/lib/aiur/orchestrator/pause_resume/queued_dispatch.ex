defmodule Aiur.Orchestrator.PauseResume.QueuedDispatch do
  @moduledoc """
  Resumes a queued issue: refresh, resumability checks, pause-override clearing, and dispatch.
  """

  alias Aiur.CodingAgent
  alias Aiur.Issue
  alias Aiur.Orchestrator.Dispatcher
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.Parking
  alias Aiur.Orchestrator.PauseResume.DeclineReason
  alias Aiur.Orchestrator.PauseResume.Resume
  alias Aiur.Orchestrator.PauseResume.TrackerControl
  alias Aiur.Orchestrator.Slots
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.Tracker

  defp clear_tracker_pause_override(%State{} = state, %{issue: %Issue{} = issue} = running_entry) do
    if Issue.paused?(issue) do
      case Resume.clear_pause_override(running_entry) do
        {:ok, cleared_entry} ->
          {:ok, Resume.put_running_entry(state, issue.id, cleared_entry), cleared_entry}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state, running_entry}
    end
  end

  defp clear_tracker_pause_override(%State{} = state, %Issue{} = issue) do
    if Issue.paused?(issue) do
      case Resume.clear_pause_override(issue) do
        {:ok, cleared_issue} ->
          state = %{state | last_polled_issues: Map.put(state.last_polled_issues, issue.id, cleared_issue)}
          {:ok, state, cleared_issue}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, state, issue}
    end
  end

  @doc false
  @spec resume_queued_issue(State.t(), term()) :: term()
  def resume_queued_issue(%State{} = state, issue_identifier) do
    case TrackerControl.find_issue_id_by_identifier(state, issue_identifier) do
      {:error, :unknown_issue} ->
        {{:error, :no_running_agent}, state}

      {:ok, issue_id} ->
        cached_issue = Map.fetch!(state.last_polled_issues, issue_id)
        refresh_queued_issue(state, cached_issue)
    end
  end

  defp refresh_queued_issue(state, cached_issue) do
    case Tracker.fetch_issue_states_by_ids([cached_issue.id]) do
      {:ok, [%Issue{} = tracker_issue | _]} ->
        state = put_in(state.last_polled_issues[tracker_issue.id], tracker_issue)
        resume_refreshed_queued_issue(state, cached_issue, tracker_issue)

      {:ok, []} ->
        state = %{state | last_polled_issues: Map.delete(state.last_polled_issues, cached_issue.id)}
        {{:error, :tracker_issue_not_found}, state}

      {:error, reason} ->
        {{:error, {:tracker_refresh_failed, reason}}, state}
    end
  end

  defp resume_refreshed_queued_issue(state, cached_issue, tracker_issue) do
    case queued_issue_resumability(state, tracker_issue) do
      :ok ->
        clear_and_resume_queued_issue(state, tracker_issue)

      {:error, reason} ->
        {{:error, maybe_stale_tracker_reason(reason, cached_issue, tracker_issue)}, state}
    end
  end

  # An explicit resume clears the tracker `agent:paused` override before it
  # dispatches, so the reconciler cannot pause the fresh agent straight back
  # off the label the operator just resumed past (#1668).
  defp clear_and_resume_queued_issue(state, issue) do
    Parking.clear_and_resume_queued_issue(state, issue, &clear_tracker_pause_override/2, &refresh_cleared_queued_issue/2)
  end

  # Removing `agent:paused` is a tracker mutation, so the copy edited locally
  # by clear_tracker_pause_override/2 is not authoritative. Re-read after the
  # mutation and run the final decision through the same policy as polling;
  # otherwise a simultaneous relabel can dispatch work that is no longer
  # eligible, or bypass a newly-created runtime claim.
  defp refresh_cleared_queued_issue(state, cleared_issue) do
    case Tracker.fetch_issue_states_by_ids([cleared_issue.id]) do
      {:ok, [%Issue{} = tracker_issue | _]} ->
        state = put_in(state.last_polled_issues[tracker_issue.id], tracker_issue)

        case DispatchPolicy.manual_resume_decision(tracker_issue, state) do
          :dispatch ->
            Dispatcher.dispatch_prevalidated_issue(state, tracker_issue)

          {:skip, reason} ->
            reason = DeclineReason.resume_decline_reason(reason, tracker_issue, state)
            {{:error, maybe_stale_tracker_reason(reason, cleared_issue, tracker_issue)}, state}
        end

      {:ok, []} ->
        state = %{state | last_polled_issues: Map.delete(state.last_polled_issues, cleared_issue.id)}
        {{:error, :tracker_issue_not_found}, state}

      {:error, reason} ->
        {{:error, {:tracker_refresh_failed, reason}}, state}
    end
  end

  @doc false
  @spec queued_issue_resumability(State.t(), term()) :: term()
  def queued_issue_resumability(state, issue) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()
    tracker_state = DispatchPolicy.normalize_issue_state(issue.state)

    with :ok <- tracker_issue_resumability(issue, active_states, terminal_states, tracker_state),
         :ok <- dependency_resumability(issue, terminal_states) do
      queued_issue_runtime_resumability(state, issue, tracker_state)
    end
  end

  defp tracker_issue_resumability(issue, active_states, terminal_states, tracker_state) do
    cond do
      not DispatchPolicy.issue_routable_to_worker?(issue) ->
        {:error, :not_routable_to_worker}

      not DispatchPolicy.issue_dispatch_authorized?(issue) ->
        {:error, :dispatch_not_authorized}

      not DispatchPolicy.active_issue_state?(issue.state, active_states) or
          DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) ->
        {:error, {:tracker_state_not_resumable, tracker_state}}

      true ->
        :ok
    end
  end

  defp dependency_resumability(issue, terminal_states) do
    if DispatchPolicy.todo_issue_held_by_dependency?(issue, terminal_states) do
      {:error, :waiting_for_dependencies}
    else
      :ok
    end
  end

  defp queued_issue_runtime_resumability(state, issue, tracker_state) do
    cond do
      MapSet.member?(state.claimed, issue.id) ->
        {:error, :already_claimed}

      # Manual start (Executor pressed space on a queued ticket): paused
      # agents are excluded from the cap so the Executor can fill a free
      # active slot even when a paused agent is parked in `running`.
      State.active_running_count(state.running) >= Slots.max_concurrent_agent_limit(state) ->
        {:error, :max_concurrent_agents_reached}

      # A lifetime-latched ticket is not resume-clearable by design. Name the
      # latch as the reason instead of letting the dispatch no-op silently and
      # reporting `:dispatch_failed`, which reads as a transient hiccup (#1453).
      match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(state, issue.id)) ->
        {:error, :lifetime_dispatch_latch}

      not DispatchPolicy.state_slots_available?(issue, state) ->
        {:error, {:state_concurrency_limit_reached, tracker_state}}

      not Slots.worker_slots_available?(state) ->
        {:error, :no_worker_capacity}

      true ->
        :ok
    end
  end

  @doc false
  @spec maybe_stale_tracker_reason(term(), term(), term()) :: term()
  def maybe_stale_tracker_reason(reason, cached_issue, tracker_issue) do
    cached = dispatchability_fingerprint(cached_issue)
    tracker = dispatchability_fingerprint(tracker_issue)
    changed_fields = for {field, value} <- cached, Map.fetch!(tracker, field) != value, do: field

    if changed_fields != [] do
      details = %{
        cached_state: cached.state,
        tracker_state: tracker.state,
        cached_paused: cached.paused,
        tracker_paused: tracker.paused,
        changed_fields: changed_fields
      }

      {:stale_tracker_state, reason, details}
    else
      reason
    end
  end

  defp dispatchability_fingerprint(issue) do
    %{
      state: DispatchPolicy.normalize_issue_state(issue.state),
      paused: Issue.paused?(issue),
      routable: DispatchPolicy.issue_routable_to_worker?(issue),
      authorized: DispatchPolicy.issue_dispatch_authorized?(issue),
      blockers: blocker_states(issue.blocked_by)
    }
  end

  defp blocker_states(blockers) when is_list(blockers) do
    Enum.map(blockers, fn
      %{state: state} -> DispatchPolicy.normalize_issue_state(state)
      _ -> :unknown
    end)
  end

  defp blocker_states(_blockers), do: [:unknown]

  # Retained for the dependency-wake path's tests (#1821). The operator resume
  # path above now re-reads the tracker first and dispatches through
  # `Dispatcher.dispatch_prevalidated_issue/2`, which reports the same failure
  # reasons from the freshly-read issue.
  @doc false
  @spec dispatch_resumed_queued_issue(State.t(), Issue.t(), keyword()) ::
          {{:ok, :started} | {:error, term()}, State.t()}
  def dispatch_resumed_queued_issue(state, issue, opts \\ []) do
    decision = Keyword.get(opts, :dispatch_decision_fun, &resumed_dispatch_decision/2)

    case decision.(issue, state) do
      :dispatch ->
        dispatch = Keyword.get(opts, :dispatch_fun, &Dispatcher.dispatch_issue/2)
        next_state = dispatch.(state, issue)

        cond do
          MapSet.member?(next_state.claimed, issue.id) ->
            {{:ok, :started}, next_state}

          TrackerTasks.issue_pending?(next_state, issue.id) ->
            {{:ok, :pending}, next_state}

          match?({:lifetime, _, _}, Dispatcher.dispatch_latch_status(next_state, issue.id)) ->
            {{:error, :lifetime_dispatch_latch}, next_state}

          true ->
            {{:error, {:dispatch_failed, dispatch_failure_reason(next_state, issue)}}, next_state}
        end

      {:skip, reason} ->
        {{:error, {:dispatch_failed, dispatch_decline_failure_reason(state, issue, reason)}}, state}
    end
  end

  defp resumed_dispatch_decision(issue, state) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()

    if DispatchPolicy.dispatch_candidate?(issue, state, active_states, terminal_states),
      do: :dispatch,
      else: DispatchPolicy.dispatch_decision(issue, state, active_states, terminal_states)
  end

  @doc false
  @spec dispatch_failure_reason(State.t(), term()) :: term()
  def dispatch_failure_reason(state, issue) do
    cond do
      Map.has_key?(state.dispatch_declines, issue.id) ->
        dispatch_decline_failure_reason(state, issue, Map.fetch!(state.dispatch_declines, issue.id))

      MapSet.member?(state.model_fallback_waiting, issue.id) ->
        :all_backends_usage_limited

      not is_nil(get_in(state.dispatch_recovery.codex_thrash_budget, [issue.id, :tripped])) ->
        :thrash_circuit_open

      CodingAgent.remote_worker?(CodingAgent.backend_for(issue)) and not Slots.worker_slots_available?(state) ->
        :no_worker_capacity

      Map.has_key?(state.retry_attempts, issue.id) ->
        {:worker_start_failed, Map.fetch!(state.retry_attempts, issue.id)}

      true ->
        :cause_unknown
    end
  end

  defp dispatch_decline_failure_reason(_state, _issue, :worker_capacity), do: :no_worker_capacity
  defp dispatch_decline_failure_reason(_state, _issue, :state_capacity), do: :state_capacity
  defp dispatch_decline_failure_reason(_state, _issue, :fleet_capacity), do: :fleet_capacity
  defp dispatch_decline_failure_reason(_state, _issue, :model_fallback_waiting), do: :all_backends_usage_limited

  defp dispatch_decline_failure_reason(state, issue, :retry_backoff) do
    case Map.fetch(state.retry_attempts, issue.id) do
      {:ok, reason} -> {:worker_start_failed, reason}
      :error -> {:dispatch_declined, :retry_backoff}
    end
  end

  defp dispatch_decline_failure_reason(_state, _issue, reason), do: {:dispatch_declined, reason}
end
