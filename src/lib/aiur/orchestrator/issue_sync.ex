defmodule Aiur.Orchestrator.IssueSync do
  @moduledoc """
  Synchronizes polled issues into orchestrator state and derived events.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentQueue, AgentQueueStore, AlertFeed, Alerts, CodingAgent, Config, CurrentRunMembership, DispatchBudgetStore, Issue, Tracker, TrackerIdentity}
  alias Aiur.Config.Paths
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{AutoSubscriptions, DispatchPolicy, MembershipLifecycle, OperatorMessages, PushRouting, Reconciler, Slots, State}

  @idle_terminal_verification_batch_size 25
  @capacity_starvation_alert_after_ms 60_000
  @fleet_capacity_low_load_ratio 0.5

  @spec sync_polled_issue_state(State.t(), list()) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues) when is_list(issues) do
    sync_polled_issue_state(
      state,
      issues,
      &Tracker.fetch_issue_states_by_ids/1,
      &MembershipLifecycle.observe/2,
      DispatchPolicy.terminal_state_set(),
      &CurrentRunMembership.mark_reconciled/1
    )
  end

  def sync_polled_issue_state(%State{} = state, _issues), do: state

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term())
        ) :: State.t()
  def sync_polled_issue_state(%State{} = state, issues, fetch_issue_states_fun, observe_membership_fun)
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      DispatchPolicy.terminal_state_set()
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t()
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      &CurrentRunMembership.mark_reconciled/1,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) do
    sync_polled_issue_state(
      state,
      issues,
      fetch_issue_states_fun,
      observe_membership_fun,
      terminal_states,
      mark_reconciled_fun,
      &CurrentRunMembership.set_terminal_verification_pending/2
    )
  end

  @doc false
  @spec sync_polled_issue_state(
          State.t(),
          list(),
          ([String.t()] -> {:ok, [term()]} | {:error, term()}),
          (TrackerIdentity.t(), atom() -> term()),
          MapSet.t(),
          (:fresh | :unavailable -> term()),
          (TrackerIdentity.t(), boolean() -> term())
        ) :: State.t()
  def sync_polled_issue_state(
        %State{} = state,
        issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )
      when is_list(issues) and is_function(fetch_issue_states_fun, 1) and is_function(observe_membership_fun, 2) and
             is_struct(terminal_states, MapSet) and is_function(mark_reconciled_fun, 1) and
             is_function(set_terminal_verification_pending_fun, 2) do
    state = %{state | active_attention_topics: active_attention_topics()}
    state = Reconciler.resolve_orphaned_divergence_attentions(state)
    previous_issues = state.last_polled_issues
    current_issues = issues_by_id(issues)

    retained_issues =
      record_disappearing_idle_terminals(
        state,
        previous_issues,
        current_issues,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        mark_reconciled_fun,
        set_terminal_verification_pending_fun
      )

    state =
      Enum.reduce(issues, state, fn issue, state_acc ->
        previous_issue = Map.get(previous_issues, issue.id)

        state_acc
        |> emit_task_state_transition_alert(previous_issue, issue)
        |> emit_tracker_pause_transition_alert(previous_issue, issue)
        |> emit_dependency_transition_events(previous_issue, issue)
      end)

    # `issues` is the active poll: pass it so the recheck prefers a freshly
    # polled blockee over the snapshot stored in the running entry.
    state = PushRouting.recheck_cleared_dependency_pauses(state, fetch_issue_states_fun, issues)

    %{state | last_polled_issues: retained_issues}
  end

  defp issues_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
  end

  defp active_attention_topics do
    [log_roots: [Paths.log_root_dir()], needs_attention: true]
    |> AlertFeed.list()
    |> MapSet.new(& &1["topic"])
  end

  defp record_disappearing_idle_terminals(
         %State{} = state,
         previous_issues,
         current_issues,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         mark_reconciled_fun,
         set_terminal_verification_pending_fun
       ) do
    disappearing_idle_issue_ids =
      previous_issues
      |> Map.keys()
      |> Enum.reject(fn issue_id ->
        Map.has_key?(current_issues, issue_id) or
          Map.has_key?(state.running, issue_id) or
          Map.has_key?(state.retry_attempts, issue_id)
      end)
      |> Enum.sort()

    pending_issue_ids =
      record_refreshed_terminal_membership(
        disappearing_idle_issue_ids,
        fetch_issue_states_fun,
        observe_membership_fun,
        terminal_states,
        set_terminal_verification_pending_fun
      )

    retain_pending_terminal_verification(
      pending_issue_ids,
      mark_reconciled_fun,
      set_terminal_verification_pending_fun
    )

    Map.merge(current_issues, Map.take(previous_issues, pending_issue_ids))
  end

  defp record_refreshed_terminal_membership(
         [],
         _fetch_issue_states_fun,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: []

  defp record_refreshed_terminal_membership(
         issue_ids,
         fetch_issue_states_fun,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    {verification_issue_ids, deferred_issue_ids} =
      Enum.split(issue_ids, @idle_terminal_verification_batch_size)

    disappeared_issue_ids = MapSet.new(verification_issue_ids)

    case fetch_issue_states_fun.(verification_issue_ids) do
      {:ok, refreshed_issues} when is_list(refreshed_issues) ->
        returned_issue_ids =
          refreshed_issues
          |> Enum.flat_map(fn
            %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
            _issue -> []
          end)
          |> MapSet.new()

        failed_issue_ids =
          Enum.reduce(
            refreshed_issues,
            MapSet.difference(disappeared_issue_ids, returned_issue_ids),
            fn issue, failed_issue_ids ->
              issue
              |> record_refreshed_terminal_member(
                disappeared_issue_ids,
                observe_membership_fun,
                terminal_states,
                set_terminal_verification_pending_fun
              )
              |> retain_refreshed_terminal_verification(
                failed_issue_ids,
                issue,
                set_terminal_verification_pending_fun
              )
            end
          )

        MapSet.to_list(failed_issue_ids) ++ deferred_issue_ids

      _result ->
        verification_issue_ids ++ deferred_issue_ids
    end
  end

  defp record_refreshed_terminal_member(
         %Issue{id: _issue_id} = issue,
         disappeared_issue_ids,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    if terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
      record_and_clear_refreshed_terminal(
        issue,
        observe_membership_fun,
        set_terminal_verification_pending_fun
      )
    else
      :not_terminal
    end
  end

  defp record_refreshed_terminal_member(
         _issue,
         _disappeared_issue_ids,
         _observe_membership_fun,
         _terminal_states,
         _set_terminal_verification_pending_fun
       ),
       do: :not_terminal

  defp retain_refreshed_terminal_verification(
         result,
         failed_issue_ids,
         issue,
         _set_terminal_verification_pending_fun
       )
       when result in [:ok, :not_terminal] do
    MapSet.delete(failed_issue_ids, issue.id)
  end

  defp retain_refreshed_terminal_verification(
         {:error, _reason},
         failed_issue_ids,
         issue,
         set_terminal_verification_pending_fun
       ) do
    _ =
      safely_set_terminal_verification_pending(
        set_terminal_verification_pending_fun,
        issue.tracker_identity,
        true
      )

    MapSet.put(failed_issue_ids, issue.id)
  end

  defp terminal_disappearing_issue?(issue, disappeared_issue_ids, terminal_states) do
    MapSet.member?(disappeared_issue_ids, issue.id) and
      DispatchPolicy.terminal_issue_state?(issue.state, terminal_states)
  end

  defp record_and_clear_refreshed_terminal(
         issue,
         observe_membership_fun,
         set_terminal_verification_pending_fun
       ) do
    case MembershipLifecycle.record(
           issue,
           MembershipLifecycle.terminal_lifecycle(issue.state),
           observe_membership_fun
         ) do
      :ok ->
        clear_refreshed_terminal_verification(
          issue,
          set_terminal_verification_pending_fun
        )

      error ->
        error
    end
  end

  defp clear_refreshed_terminal_verification(issue, set_terminal_verification_pending_fun) do
    case safely_set_terminal_verification_pending(
           set_terminal_verification_pending_fun,
           issue.tracker_identity,
           false
         ) do
      :ok -> :ok
      :error -> {:error, :terminal_verification_marker_failed}
    end
  end

  defp retain_pending_terminal_verification([], _mark_reconciled_fun, _set_terminal_verification_pending_fun), do: :ok

  defp retain_pending_terminal_verification(
         pending_issue_ids,
         mark_reconciled_fun,
         _set_terminal_verification_pending_fun
       )
       when is_list(pending_issue_ids) do
    safely_mark_reconciled(mark_reconciled_fun, :unavailable)
  end

  defp safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, identity, pending?) do
    case set_terminal_verification_pending_fun.(identity, pending?) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safely_mark_reconciled(mark_reconciled_fun, status) do
    _ = mark_reconciled_fun.(status)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_dependency_transition_events(%State{} = state, previous_issue, %Issue{} = issue) do
    if is_nil(previous_issue) do
      state
    else
      previous_blockers = blocker_map(previous_issue)
      current_blockers = blocker_map(issue)

      added_blocker_ids = Map.keys(current_blockers) -- Map.keys(previous_blockers)
      removed_blocker_ids = Map.keys(previous_blockers) -- Map.keys(current_blockers)
      shared_blocker_ids = Map.keys(current_blockers) -- added_blocker_ids

      state =
        Enum.reduce(added_blocker_ids, state, fn blocker_id, state_acc ->
          AutoSubscriptions.auto_subscribe_for_dependency(issue, current_blockers[blocker_id])

          enqueue_dependency_event(
            state_acc,
            issue,
            current_blockers[blocker_id],
            :dependency_added
          )
        end)

      state =
        Enum.reduce(removed_blocker_ids, state, fn blocker_id, state_acc ->
          AutoSubscriptions.auto_unsubscribe_for_dependency(issue, previous_blockers[blocker_id])

          enqueue_dependency_event(
            state_acc,
            issue,
            previous_blockers[blocker_id],
            :dependency_removed
          )
          |> PushRouting.maybe_resume_blockee_on_cleared_dependency(issue, previous_blockers[blocker_id], :removed)
        end)

      Enum.reduce(shared_blocker_ids, state, fn blocker_id, state_acc ->
        maybe_enqueue_blocker_terminality_event(
          state_acc,
          issue,
          previous_blockers[blocker_id],
          current_blockers[blocker_id]
        )
      end)
    end
  end

  defp emit_dependency_transition_events(%State{} = state, _previous_issue, _issue), do: state

  defp emit_task_state_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if DispatchPolicy.state_slug(issue.state) == "error" do
      emit_observed_error_transition_alert(state, issue)
    else
      resolve_observed_error_transition_alert(state, issue)
    end
  end

  defp emit_task_state_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    previous_state = DispatchPolicy.state_slug(previous_issue.state)
    current_state = DispatchPolicy.state_slug(issue.state)

    cond do
      is_nil(current_state) ->
        state

      previous_state == current_state ->
        reconcile_observed_error_alert(state, issue, current_state)

      current_state == "error" ->
        emit_observed_error_transition_alert(state, issue)

      previous_state == "error" ->
        resolve_observed_error_transition_alert(state, issue)

      true ->
        # Ticket B: label-flip alerts route through the new topic shape so
        # the alerts file can glob-match per state without one entry per state.
        Alerts.emit_system(
          "ticket.#{issue.identifier}.issue.label.added.agent.#{current_state}",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: task_state_alert_reason(current_state),
          needs_attention: task_state_needs_attention?(current_state),
          severity: task_state_alert_severity(current_state)
        )

        clear_observed_error_alert(state, issue.id)
    end
  end

  defp emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp reconcile_observed_error_alert(state, issue, "error"),
    do: emit_observed_error_transition_alert(state, issue)

  defp reconcile_observed_error_alert(state, issue, _state),
    do: resolve_observed_error_transition_alert(state, issue)

  defp emit_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    if MapSet.member?(state.observed_error_alerts, issue.id) or active_attention?(state, topic) do
      mark_observed_error_alert(state, issue.id, cause)
    else
      message = observed_error_alert_message(cause)

      case Alerts.emit_system(topic,
             issue: issue,
             worker_host: Orchestrator.running_worker_host(state, issue.id),
             reason: message,
             needs_attention: true,
             severity: "warning",
             central: true
           ) do
        :ok -> mark_observed_error_alert(state, issue.id, cause)
        {:error, _reason} -> state
      end
    end
  end

  defp resolve_observed_error_transition_alert(%State{} = state, %Issue{} = issue) do
    cause = observed_error_alert_cause(state, issue)
    topic = observed_error_alert_topic(issue, cause)

    active? =
      MapSet.member?(state.observed_error_alerts, issue.id) or
        active_attention?(state, topic)

    cond do
      cause == :lifetime_latch and lifetime_latch_status(state, issue.id) != :inactive ->
        mark_observed_error_alert(state, issue.id, cause)

      active? ->
        case Alerts.emit_system("#{topic}.resolved",
               issue: issue,
               worker_host: Orchestrator.running_worker_host(state, issue.id),
               reason: "Tracker moved the ticket out of agent:error; the observed error condition is resolved.",
               needs_attention: false,
               severity: "info",
               central: true
             ) do
          :ok -> clear_observed_error_alert(state, issue.id)
          {:error, _reason} -> state
        end

      true ->
        state
    end
  end

  defp observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    cond do
      lifetime_latch_active?(state, issue.id) -> :lifetime_latch
      cause = Map.get(state.observed_error_alert_causes, issue.id) -> cause
      cause = persisted_observed_error_alert_cause(state, issue) -> cause
      true -> :observed_tracker_error
    end
  end

  defp persisted_observed_error_alert_cause(%State{} = state, %Issue{} = issue) do
    Enum.find([:lifetime_latch, :retry_exhausted, :observed_tracker_error], fn cause ->
      active_attention?(state, observed_error_alert_topic(issue, cause))
    end)
  end

  defp active_attention?(state, topic), do: MapSet.member?(state.active_attention_topics, topic)

  defp lifetime_latch_active?(%State{} = state, issue_id) when is_binary(issue_id) do
    lifetime_latch_status(state, issue_id) == :active
  end

  defp lifetime_latch_active?(_state, _issue_id), do: false

  defp lifetime_latch_status(%State{} = state, issue_id) when is_binary(issue_id) do
    maximum = Config.agent_max_dispatches_per_ticket()
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget, issue_id]) || %{}

    # A trip recorded in the live recovery state remains authoritative until
    # the dispatch budget explicitly clears it. Configuration may be reloaded
    # between the trip and this tracker observation, so do not reinterpret an
    # already-recorded latch through the current cap.
    memory_latched? = budget[:tripped] == :lifetime

    if memory_latched?, do: :active, else: persisted_latch_status(maximum, issue_id)
  end

  defp lifetime_latch_status(_state, _issue_id), do: :inactive

  defp persisted_latch_status(maximum, issue_id) when maximum > 0 do
    case DispatchBudgetStore.lifetime(issue_id) do
      {:ok, lifetime} when lifetime >= maximum -> :active
      {:ok, _lifetime} -> :inactive
      {:error, _reason} -> :unknown
    end
  end

  defp persisted_latch_status(_maximum, _issue_id), do: :inactive

  defp observed_error_alert_message(:lifetime_latch),
    do: "Agent remains in error because its lifetime dispatch latch is still active; Executor action is required."

  defp observed_error_alert_message(_cause),
    do:
      "Tracker observed agent:error without a specialized local cause; the ticket needs Executor review. " <>
        "This condition will not clear on its own until the ticket is moved out of error."

  defp observed_error_alert_topic(%Issue{} = issue, cause) do
    "ticket.#{issue.identifier}.agent.attention.error-#{cause}"
  end

  defp mark_observed_error_alert(state, issue_id, cause) do
    %{
      state
      | observed_error_alerts: MapSet.put(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.put(state.observed_error_alert_causes, issue_id, cause)
    }
  end

  defp clear_observed_error_alert(state, issue_id) do
    %{
      state
      | observed_error_alerts: MapSet.delete(state.observed_error_alerts, issue_id),
        observed_error_alert_causes: Map.delete(state.observed_error_alert_causes, issue_id)
    }
  end

  defp emit_tracker_pause_transition_alert(%State{} = state, nil, %Issue{} = issue) do
    if Issue.paused?(issue) do
      emit_tracker_pause_alert(state, issue)
    else
      resolve_tracker_pause_alert(state, issue)
    end

    state
  end

  defp emit_tracker_pause_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    case {Issue.paused?(previous_issue), Issue.paused?(issue)} do
      {false, true} ->
        emit_tracker_pause_alert(state, issue)

      {true, false} ->
        Alerts.emit_system("ticket.#{issue.identifier}.agent.unpaused",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: "Tracker removed agent:paused; tracker=agent:#{issue.state}. No operator action is needed.",
          needs_attention: false,
          severity: "info"
        )

        resolve_tracker_pause_alert(state, issue, true)

      _ ->
        :ok
    end

    state
  end

  defp emit_tracker_pause_transition_alert(%State{} = state, _previous_issue, _issue), do: state

  defp emit_tracker_pause_alert(%State{} = state, %Issue{} = issue) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    unless active_attention?(state, topic) do
      Alerts.emit_system(topic,
        issue: issue,
        worker_host: Orchestrator.running_worker_host(state, issue.id),
        reason:
          "Tracker added agent:paused (tracker pause override); tracker=agent:#{issue.state}. " <>
            "This clears when the operator removes agent:paused.",
        needs_attention: true,
        severity: "warning",
        central: true
      )
    end
  end

  defp resolve_tracker_pause_alert(state, issue), do: resolve_tracker_pause_alert(state, issue, false)

  defp resolve_tracker_pause_alert(%State{} = state, %Issue{} = issue, force?) do
    topic = "ticket.#{issue.identifier}.agent.paused"

    if force? or active_attention?(state, topic) do
      Alerts.emit_system("#{topic}.resolved",
        issue: issue,
        worker_host: Orchestrator.running_worker_host(state, issue.id),
        reason: "Tracker removed agent:paused; the tracker pause override is resolved.",
        needs_attention: false,
        severity: "info",
        central: true
      )
    else
      :ok
    end
  end

  defp task_state_alert_reason("human-review"),
    do: "Agent marked the ticket ready for human review"

  defp task_state_alert_reason(_state), do: nil

  defp task_state_needs_attention?("human-review"), do: true
  defp task_state_needs_attention?(_state), do: false

  defp task_state_alert_severity("human-review"), do: "warning"
  defp task_state_alert_severity(_state), do: nil

  @spec blocker_map(term()) :: map()
  def blocker_map(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.reduce(blockers, %{}, fn
      %{id: blocker_id} = blocker, acc when is_binary(blocker_id) ->
        Map.put(acc, blocker_id, blocker)

      _blocker, acc ->
        acc
    end)
  end

  def blocker_map(_issue), do: %{}

  defp blocker_terminal?(%{state: state_name}) when is_binary(state_name) do
    DispatchPolicy.terminal_issue_state?(state_name, DispatchPolicy.terminal_state_set())
  end

  defp blocker_terminal?(_blocker), do: false

  defp maybe_enqueue_blocker_terminality_event(state, issue, previous_blocker, current_blocker) do
    cond do
      blocker_terminal?(previous_blocker) and !blocker_terminal?(current_blocker) ->
        enqueue_dependency_event(state, issue, current_blocker, :blocker_became_non_terminal)

      !blocker_terminal?(previous_blocker) and blocker_terminal?(current_blocker) ->
        state
        |> enqueue_dependency_event(issue, current_blocker, :blocker_became_terminal)
        |> PushRouting.maybe_resume_blockee_on_cleared_dependency(issue, current_blocker)

      true ->
        state
    end
  end

  @doc false
  @spec enqueue_dependency_event(State.t(), Issue.t(), map(), atom()) :: State.t()
  def enqueue_dependency_event(%State{} = state, %Issue{} = issue, blocker, update_kind)
      when is_map(blocker) do
    body = blocker_event_body(issue, blocker, update_kind)

    {queue_store, item} =
      AgentQueue.coordination_event(issue.identifier, update_kind, body,
        source: :tracker,
        dedupe_key: dependency_event_dedupe_key(issue, blocker, update_kind),
        causal_refs: dependency_causal_refs(issue, blocker),
        subscription: dependency_subscription(issue, blocker)
      )
      |> then(&AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case State.find_running_by_identifier(state.running, issue.identifier) do
      nil ->
        next_state

      running_entry ->
        OperatorMessages.notify_running_queue_update(running_entry, item)
        next_state
    end
  end

  def enqueue_dependency_event(%State{} = state, _issue, _blocker, _update_kind), do: state

  defp blocker_event_body(issue, blocker, update_kind) do
    %{
      blocked_issue_id: issue.id,
      blocked_issue_identifier: issue.identifier,
      blocker_issue_id: blocker[:id],
      blocker_issue_identifier: blocker[:identifier],
      blocker_state: blocker[:state],
      update_kind: update_kind,
      summary: blocker_event_summary(issue, blocker, update_kind)
    }
  end

  defp blocker_event_summary(_issue, blocker, :dependency_added),
    do: "Issue is now blocked by #{blocker[:identifier] || blocker[:id]}"

  defp blocker_event_summary(_issue, blocker, :dependency_removed),
    do: "Dependency on #{blocker[:identifier] || blocker[:id]} was removed"

  defp blocker_event_summary(_issue, blocker, :blocker_became_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} reached terminal state #{blocker[:state]}"

  defp blocker_event_summary(_issue, blocker, :blocker_became_non_terminal),
    do: "Blocker #{blocker[:identifier] || blocker[:id]} returned to non-terminal state #{blocker[:state]}"

  defp dependency_event_dedupe_key(issue, blocker, update_kind) do
    [
      Atom.to_string(update_kind),
      issue.id || issue.identifier,
      blocker[:id] || blocker[:identifier],
      blocker[:state]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(":")
  end

  defp dependency_causal_refs(issue, blocker) do
    [issue.id, blocker[:id]]
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_subscription(issue, blocker) do
    %{
      subscription_type: :blocked_by,
      source_issue_id: blocker[:id],
      target_issue_id: issue.id
    }
  end

  @spec sync_todo_capacity_alert(State.t(), list()) :: State.t()
  def sync_todo_capacity_alert(%State{} = state, issues) when is_list(issues) do
    todo_issues = routable_todo_issues(issues)

    over_capacity? = length(todo_issues) > Slots.max_concurrent_agent_limit(state)

    cond do
      over_capacity? and not state.todo_over_capacity_alert_active ->
        emit_todo_capacity_alert(state, todo_issues)
        %{state | todo_over_capacity_alert_active: true}

      not over_capacity? and state.todo_over_capacity_alert_active ->
        %{state | todo_over_capacity_alert_active: false}

      true ->
        state
    end
  end

  def sync_todo_capacity_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_capacity_starvation_alert(State.t(), list(), integer()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    constraint_entries = capacity_constraint_entries(state, issues)

    state
    |> capacity_starvation_context(issues, constraint_entries)
    |> sync_capacity_starvation_state(now_ms)
  end

  def sync_capacity_starvation_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_capacity_starvation_alert(State.t(), list()) :: State.t()
  def sync_capacity_starvation_alert(%State{} = state, issues) when is_list(issues),
    do: sync_capacity_starvation_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_capacity_starvation_alert(%State{} = state, _issues), do: state

  @doc false
  @spec sync_fleet_capacity_starved_alert(State.t(), list(), integer()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    context = fleet_capacity_context(state, issues)

    if fleet_capacity_starved?(context) do
      sync_fleet_capacity_starvation(state, context, now_ms)
    else
      clear_fleet_capacity_starvation(state)
    end
  end

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_fleet_capacity_starved_alert(State.t(), list()) :: State.t()
  def sync_fleet_capacity_starved_alert(%State{} = state, issues) when is_list(issues),
    do: sync_fleet_capacity_starved_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_fleet_capacity_starved_alert(%State{} = state, _issues), do: state

  defp fleet_capacity_context(state, issues) do
    sample = state.dispatch_capacity_sample
    constraint_entries = capacity_constraint_entries(state, issues)
    ready_issues = ready_dispatch_issues(state, issues)
    live_count = State.active_running_count(state.running)
    effective_cap = Slots.effective_concurrent_agent_limit(state)

    %{
      state: state,
      ready_count: length(ready_issues),
      live_count: live_count,
      occupied_slots: Slots.used_slots(state),
      effective_cap: effective_cap,
      configured_cap: Slots.max_concurrent_agent_limit(state),
      load: Map.get(sample, :load),
      target: Map.get(sample, :target),
      schedulers: Map.get(sample, :schedulers),
      binding_constraint: selected_binding_constraint(state, constraint_entries, ready_issues)
    }
  end

  defp fleet_capacity_starved?(context) do
    not context.state.globally_paused and context.ready_count > context.live_count and low_load?(context)
  end

  defp low_load?(%{load: load, target: target, schedulers: schedulers})
       when is_number(load) and is_number(target) and target > 0 and is_integer(schedulers) and schedulers > 0,
       do: load < target * schedulers * @fleet_capacity_low_load_ratio

  defp low_load?(_context), do: false

  defp sync_fleet_capacity_starvation(state, context, now_ms) do
    starvation = state.fleet_capacity_starvation

    if is_integer(starvation[:effective_cap]) and starvation[:effective_cap] != context.effective_cap do
      put_fleet_capacity_starvation(state, now_ms, starvation[:alert_active] || false, context.effective_cap)
    else
      since_ms = starvation[:since_ms] || now_ms

      if starvation[:alert_active] or now_ms - since_ms < @capacity_starvation_alert_after_ms do
        put_fleet_capacity_starvation(state, since_ms, starvation[:alert_active] || false, context.effective_cap)
      else
        emit_fleet_capacity_starvation(state, context, since_ms)
      end
    end
  end

  defp emit_fleet_capacity_starvation(state, context, since_ms) do
    case Alerts.emit_system("system.fleet.capacity.starved",
           reason: fleet_capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        state
        |> Map.put(:fleet_capacity_starvation_resolution_emitted, false)
        |> put_fleet_capacity_starvation(since_ms, true, context.effective_cap)

      {:error, _reason} ->
        put_fleet_capacity_starvation(state, since_ms, false, context.effective_cap)
    end
  end

  defp fleet_capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{context.live_count}, " <>
      "load=#{context.load}/#{context.target * context.schedulers}, effective cap=#{context.effective_cap}, " <>
      "configured cap=#{context.configured_cap}; binding constraint=#{fleet_capacity_constraint(context)}."
  end

  defp fleet_capacity_constraint(%{binding_constraint: constraint}) when is_binary(constraint), do: constraint

  defp fleet_capacity_constraint(%{occupied_slots: occupied, live_count: live}) when occupied > live,
    do: "paused agent reservations (occupied slots=#{occupied})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective < configured,
       do: "load envelope (effective cap=#{effective})"

  defp fleet_capacity_constraint(%{effective_cap: effective, configured_cap: configured, live_count: live})
       when effective <= live and effective == configured,
       do: "configured concurrency ceiling (cap=#{configured})"

  defp fleet_capacity_constraint(_context), do: "no binding constraint identified"

  defp selected_binding_constraint(%State{prewarm_blocked_alert_active: true}, entries, _ready_issues) do
    entries |> Enum.find(&(&1.identity == "build")) |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(%State{capacity_hold: %{signal: signal}}, entries, _ready_issues) do
    entries
    |> Enum.find(&(&1.identity == capacity_hold_identity(signal)))
    |> then(&(&1 && &1.detail))
  end

  defp selected_binding_constraint(state, entries, ready_issues) do
    case Enum.filter(entries, &String.starts_with?(&1.identity, "per-state:")) do
      [_ | _] = per_state_entries -> Enum.map_join(per_state_entries, "; ", & &1.detail)
      _ -> model_fallback_constraint(state, ready_issues) || worker_capacity_constraint(state, ready_issues)
    end
  end

  defp model_fallback_constraint(%State{model_fallback_waiting: waiting}, ready_issues) do
    waiting_count = Enum.count(ready_issues, &MapSet.member?(waiting, &1.id))

    if waiting_count > 0 do
      "dispatch authorization denials (all fallback backends usage-limited for #{waiting_count} ready ticket(s))"
    end
  end

  defp worker_capacity_constraint(state, ready_issues) do
    if Enum.any?(ready_issues, &(CodingAgent.backend_for(&1) |> CodingAgent.remote_worker?())) and
         not Slots.worker_slots_available?(state) do
      "worker-host capacity (all SSH worker slots are occupied)"
    end
  end

  defp capacity_hold_identity(:build), do: "build-queue"
  defp capacity_hold_identity(:envelope), do: "load-envelope"
  defp capacity_hold_identity(:file_descriptors), do: "fd"
  defp capacity_hold_identity(:run_queue), do: "run-queue"
  defp capacity_hold_identity(signal), do: to_string(signal)

  defp clear_fleet_capacity_starvation(%State{fleet_capacity_starvation_resolution_emitted: true} = state),
    do: put_fleet_capacity_starvation(state, nil, false, nil)

  defp clear_fleet_capacity_starvation(%State{} = state) do
    starvation = state.fleet_capacity_starvation

    active? = starvation[:alert_active] or AlertFeed.active_system_attention?("system.fleet.capacity.starved")

    if active? do
      case Alerts.emit_system("system.fleet.capacity.starved.resolved",
             reason: "Fleet capacity is no longer starved.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok ->
          state
          |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
          |> put_fleet_capacity_starvation(nil, false, nil)

        {:error, _reason} ->
          state
      end
    else
      state
      |> Map.put(:fleet_capacity_starvation_resolution_emitted, true)
      |> put_fleet_capacity_starvation(nil, false, nil)
    end
  end

  defp put_fleet_capacity_starvation(state, since_ms, alert_active, effective_cap) do
    %{state | fleet_capacity_starvation: %{since_ms: since_ms, alert_active: alert_active, effective_cap: effective_cap}}
  end

  defp capacity_starvation_context(state, issues, constraint_entries) do
    %{
      state: state,
      configured: Slots.max_concurrent_agent_limit(state),
      effective: Slots.effective_concurrent_agent_limit(state),
      ready_count: state |> ready_dispatch_issues(issues) |> length(),
      constraints: Enum.map(constraint_entries, & &1.detail),
      signature: capacity_constraint_signature(constraint_entries)
    }
  end

  defp sync_capacity_starvation_state(%{ready_count: 0} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(%{constraints: []} = context, _now_ms),
    do: clear_capacity_starvation(context.state)

  defp sync_capacity_starvation_state(context, now_ms) do
    starvation = Map.get(context.state, :capacity_starvation, %{})
    since_by_identity = capacity_starvation_ages(starvation, context.signature, now_ms)
    alerted_identities = active_alerted_identities(starvation, context.signature)
    due_identities = due_capacity_identities(since_by_identity, alerted_identities, now_ms)

    if due_identities == [] do
      put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    else
      emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities)
    end
  end

  defp capacity_starvation_ages(starvation, identities, now_ms) do
    previous_ages = previous_capacity_starvation_ages(starvation, identities, now_ms)
    Map.new(identities, &{&1, Map.get(previous_ages, &1, now_ms)})
  end

  defp previous_capacity_starvation_ages(%{since_ms: ages}, _identities, _now_ms) when is_map(ages), do: ages

  defp previous_capacity_starvation_ages(%{since_ms: since_ms, signature: signature}, identities, _now_ms)
       when is_integer(since_ms) do
    Map.new(signature || identities, &{&1, since_ms})
  end

  defp previous_capacity_starvation_ages(_starvation, _identities, _now_ms), do: %{}

  defp active_alerted_identities(starvation, identities) do
    alerted =
      case Map.get(starvation, :alerted) do
        alerted when is_list(alerted) -> alerted
        _ -> legacy_alerted_identities(starvation, identities)
      end

    MapSet.intersection(MapSet.new(alerted), MapSet.new(identities))
  end

  defp legacy_alerted_identities(starvation, identities) do
    if Map.get(starvation, :alert_active) == true, do: starvation[:signature] || identities, else: []
  end

  defp due_capacity_identities(since_by_identity, alerted_identities, now_ms) do
    since_by_identity
    |> Enum.filter(fn {identity, since_ms} ->
      now_ms - since_ms >= @capacity_starvation_alert_after_ms and not MapSet.member?(alerted_identities, identity)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp emit_capacity_starvation_alert(context, since_by_identity, alerted_identities, due_identities) do
    next_alerted_identities = MapSet.union(alerted_identities, MapSet.new(due_identities))

    case Alerts.emit_system("system.dispatch.capacity_starved",
           reason: capacity_starvation_reason(context),
           needs_attention: true,
           severity: "warning"
         ) do
      :ok ->
        context.state
        |> put_capacity_starvation(since_by_identity, next_alerted_identities, context.signature)
        |> Map.put(:capacity_starvation_resolution_emitted, false)

      {:error, _reason} ->
        put_capacity_starvation(context.state, since_by_identity, alerted_identities, context.signature)
    end
  end

  defp capacity_starvation_reason(context) do
    "Ready tickets=#{context.ready_count}, live agents=#{State.active_running_count(context.state.running)}, " <>
      "effective cap=#{context.effective}, configured cap=#{context.configured}; " <>
      "dispatch constraints=#{Enum.join(context.constraints, "; ")}."
  end

  defp clear_capacity_starvation(%State{capacity_starvation_resolution_emitted: true} = state),
    do: put_cleared_capacity_starvation(state)

  defp clear_capacity_starvation(%State{} = state) do
    active? =
      Map.get(state.capacity_starvation, :alert_active, false) or
        AlertFeed.active_system_attention?("system.dispatch.capacity_starved")

    if active? do
      case Alerts.emit_system("system.dispatch.capacity_starved.resolved",
             reason: "Ready-work dispatch capacity recovered; fleet dispatch may resume.",
             needs_attention: false,
             severity: "info"
           ) do
        :ok -> put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
        {:error, _reason} -> state
      end
    else
      put_cleared_capacity_starvation(%{state | capacity_starvation_resolution_emitted: true})
    end
  end

  defp put_cleared_capacity_starvation(state),
    do: %{state | capacity_starvation: %{since_ms: %{}, alert_active: false, signature: [], alerted: []}}

  defp put_capacity_starvation(state, since_by_identity, alerted_identities, signature) do
    %{
      state
      | capacity_starvation: %{
          since_ms: since_by_identity,
          alert_active: MapSet.size(alerted_identities) > 0,
          signature: signature,
          alerted: alerted_identities |> MapSet.to_list() |> Enum.sort()
        }
    }
  end

  defp routable_todo_issues(issues) when is_list(issues) do
    issues
    |> Enum.filter(fn
      %Issue{} = issue ->
        DispatchPolicy.normalize_issue_state(issue.state) == "todo" and
          not Issue.paused?(issue) and
          DispatchPolicy.issue_routable_to_worker?(issue) and
          !DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, DispatchPolicy.terminal_state_set())

      _ ->
        false
    end)
    |> DispatchPolicy.sort_issues_for_dispatch()
  end

  defp ready_dispatch_issues(%State{} = state, issues) do
    active_states = DispatchPolicy.active_state_set()
    terminal_states = DispatchPolicy.terminal_state_set()

    issues
    |> Enum.filter(fn issue ->
      DispatchPolicy.candidate_issue?(issue, active_states, terminal_states) and
        !DispatchPolicy.todo_issue_blocked_by_non_terminal?(issue, terminal_states)
    end)
    |> Enum.reject(fn issue ->
      Map.has_key?(state.running, issue.id) or MapSet.member?(state.claimed, issue.id) or
        Map.has_key?(state.retry_attempts, issue.id)
    end)
  end

  defp capacity_constraint_entries(%State{} = state, issues) do
    state.dispatch_capacity_constraints
    |> Enum.flat_map(&dispatch_capacity_constraint_entry/1)
    |> Kernel.++(per_state_capacity_constraint_entries(state, issues))
    |> Kernel.++(budget_capacity_constraint_entries(state, issues))
    |> Enum.uniq_by(& &1.identity)
    |> Enum.sort_by(& &1.detail)
  end

  defp capacity_constraint_signature(constraint_entries) do
    constraint_entries
    |> Enum.map(& &1.identity)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dispatch_capacity_constraint_entry(%{kind: kind} = constraint) do
    case render_capacity_constraint(constraint) do
      detail when is_binary(detail) -> [%{identity: dispatch_constraint_identity(kind), detail: detail}]
      nil -> []
    end
  end

  defp dispatch_capacity_constraint_entry(_constraint), do: []

  defp dispatch_constraint_identity(:build), do: "build"
  defp dispatch_constraint_identity(:build_queue), do: "build-queue"
  defp dispatch_constraint_identity(:fd), do: "fd"
  defp dispatch_constraint_identity(:load), do: "load"
  defp dispatch_constraint_identity(:load_envelope), do: "load-envelope"
  defp dispatch_constraint_identity(:memory), do: "memory"
  defp dispatch_constraint_identity(:provider), do: "provider"
  defp dispatch_constraint_identity(:run_queue), do: "run-queue"
  defp dispatch_constraint_identity(kind), do: "dispatch:#{kind}"

  defp render_capacity_constraint(%{kind: :build, detail: detail}), do: "prewarm build (#{detail})"

  defp render_capacity_constraint(%{kind: :build_queue, detail: detail}),
    do: "build-queue gate (#{detail})"

  defp render_capacity_constraint(%{kind: :fd, detail: detail}), do: "FD gate (#{detail})"
  defp render_capacity_constraint(%{kind: :load, detail: detail}), do: "load gate (#{detail})"

  defp render_capacity_constraint(%{kind: :load_envelope, detail: detail}),
    do: "load-envelope limit (#{detail})"

  defp render_capacity_constraint(%{kind: :memory, detail: detail}), do: "memory gate (#{detail})"

  defp render_capacity_constraint(%{kind: :provider, detail: detail}),
    do: "provider gate (#{detail})"

  defp render_capacity_constraint(%{kind: :run_queue, detail: detail}),
    do: "run-queue gate (#{detail})"

  defp render_capacity_constraint(_constraint), do: nil

  defp per_state_capacity_constraint_entries(%State{} = state, issues) do
    configured_limits = Config.settings!().agent.max_concurrent_agents_by_state || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.map(&DispatchPolicy.normalize_issue_state(&1.state))
    |> Enum.uniq()
    |> Enum.flat_map(&per_state_capacity_constraint_entry(state, configured_limits, &1))
  end

  defp per_state_capacity_constraint_entry(state, configured_limits, issue_state) do
    with {:ok, limit} <- Map.fetch(configured_limits, issue_state),
         used <- DispatchPolicy.running_issue_count_for_state(state.running, issue_state),
         true <- used >= limit do
      [%{identity: "per-state:#{issue_state}", detail: "per-state limit (#{issue_state}=#{used}/#{limit})"}]
    else
      _ -> []
    end
  end

  defp budget_capacity_constraint_entries(%State{} = state, issues) do
    budget = get_in(state.dispatch_recovery, [:codex_thrash_budget]) || %{}

    ready_dispatch_issues(state, issues)
    |> Enum.flat_map(&budget_capacity_constraint_entry(&1.id, Map.get(budget, &1.id, %{})))
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :lifetime} = entry) do
    [%{identity: "budget:lifetime:#{issue_id}", detail: "budget latch (lifetime=#{Map.get(entry, :lifetime, 0)})"}]
  end

  defp budget_capacity_constraint_entry(issue_id, %{tripped: :window} = entry) do
    case budget_window_remaining_ms(entry, System.monotonic_time(:millisecond)) do
      remaining_ms when remaining_ms > 0 ->
        [%{identity: "budget:window:#{issue_id}", detail: "budget circuit (window, clears #{format_remaining_duration(remaining_ms)})"}]

      _ ->
        []
    end
  end

  defp budget_capacity_constraint_entry(_issue_id, _entry), do: []

  defp budget_window_remaining_ms(entry, now_ms) do
    window_ms = Config.codex_thrash_window_seconds() * 1_000
    max(0, Map.get(entry, :window_start_ms, now_ms) + window_ms - now_ms)
  end

  defp format_remaining_duration(milliseconds) when milliseconds < 60_000, do: "in <1m"
  defp format_remaining_duration(milliseconds), do: "in ~#{div(milliseconds + 59_999, 60_000)}m"

  defp emit_todo_capacity_alert(%State{} = state, todo_issues) when is_list(todo_issues) do
    case List.first(todo_issues) do
      %Issue{} = issue ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          issue: issue,
          worker_host: Orchestrator.running_worker_host(state, issue.id),
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )

      _ ->
        Alerts.emit_system("system.dispatch.todo_capacity_exceeded",
          reason: "Todo issue count exceeds the current dispatch capacity.",
          needs_attention: true,
          severity: "warning"
        )
    end
  end
end
