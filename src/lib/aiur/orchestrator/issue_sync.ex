defmodule Aiur.Orchestrator.IssueSync do
  @moduledoc """
  Synchronizes polled issues into orchestrator state and derived events.
  All functions execute inside the orchestrator GenServer process.
  """

  alias Aiur.{AgentQueue, AgentQueueStore, Alerts, CurrentRunMembership, Issue, Tracker, TrackerIdentity}
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{AutoSubscriptions, DispatchPolicy, MembershipLifecycle, OperatorMessages, Slots, State}

  @idle_terminal_verification_batch_size 25

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
        |> emit_dependency_transition_events(previous_issue, issue)
      end)

    %{state | last_polled_issues: retained_issues}
  end

  defp issues_by_id(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{id: issue_id} = issue, acc when is_binary(issue_id) -> Map.put(acc, issue_id, issue)
      _issue, acc -> acc
    end)
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
              case record_refreshed_terminal_member(
                     issue,
                     disappeared_issue_ids,
                     observe_membership_fun,
                     terminal_states,
                     set_terminal_verification_pending_fun
                   ) do
                :ok ->
                  MapSet.delete(failed_issue_ids, issue.id)

                :not_terminal ->
                  MapSet.delete(failed_issue_ids, issue.id)

                {:error, _reason} ->
                  _ = safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, issue.tracker_identity, true)
                  MapSet.put(failed_issue_ids, issue.id)
              end
            end
          )

        MapSet.to_list(failed_issue_ids) ++ deferred_issue_ids

      _result ->
        verification_issue_ids ++ deferred_issue_ids
    end
  end

  defp record_refreshed_terminal_member(
         %Issue{id: issue_id} = issue,
         disappeared_issue_ids,
         observe_membership_fun,
         terminal_states,
         set_terminal_verification_pending_fun
       ) do
    if MapSet.member?(disappeared_issue_ids, issue_id) and
         DispatchPolicy.terminal_issue_state?(issue.state, terminal_states) do
      case MembershipLifecycle.record(
             issue,
             MembershipLifecycle.terminal_lifecycle(issue.state),
             observe_membership_fun
           ) do
        :ok ->
          case safely_set_terminal_verification_pending(set_terminal_verification_pending_fun, issue.tracker_identity, false) do
            :ok -> :ok
            :error -> {:error, :terminal_verification_marker_failed}
          end

        error ->
          error
      end
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

  defp emit_task_state_transition_alert(%State{} = state, nil, %Issue{}), do: state

  defp emit_task_state_transition_alert(
         %State{} = state,
         %Issue{} = previous_issue,
         %Issue{} = issue
       ) do
    previous_state = DispatchPolicy.state_slug(previous_issue.state)
    current_state = DispatchPolicy.state_slug(issue.state)

    if previous_state != current_state and current_state != nil do
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
    end

    state
  end

  defp emit_task_state_transition_alert(%State{} = state, _previous_issue, _issue), do: state

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
        enqueue_dependency_event(state, issue, current_blocker, :blocker_became_terminal)

      true ->
        state
    end
  end

  defp enqueue_dependency_event(%State{} = state, %Issue{} = issue, blocker, update_kind)
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

  defp enqueue_dependency_event(%State{} = state, _issue, _blocker, _update_kind), do: state

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
