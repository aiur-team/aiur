defmodule Aiur.Orchestrator.IssueSync.Dependencies do
  @moduledoc """
  Reconciles dependency subscriptions, transition events, and circular waits.
  """

  require Logger

  alias Aiur.AgentQueue
  alias Aiur.AgentQueueStore
  alias Aiur.Alerts
  alias Aiur.GitHub.Config
  alias Aiur.Issue
  alias Aiur.Orchestrator.AutoSubscriptions
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.OperatorMessages
  alias Aiur.Orchestrator.PushRouting
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TicketTransition
  alias Aiur.Orchestrator.TrackerTasks

  @capacity_starvation_alert_after_ms 60_000
  @doc false
  @spec emit_dependency_transition_events(State.t(), Issue.t() | nil, term()) :: State.t()
  def emit_dependency_transition_events(%State{} = state, previous_issue, %Issue{} = issue),
    do: emit_dependency_transition_events(state, previous_issue, issue, [])

  def emit_dependency_transition_events(%State{} = state, _previous_issue, _issue), do: state

  @spec emit_dependency_transition_events(State.t(), Issue.t() | nil, term(), keyword()) :: State.t()
  def emit_dependency_transition_events(%State{} = state, previous_issue, %Issue{} = issue, opts) do
    state = sync_dependency_reason_label(state, previous_issue, issue, opts)

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
          blocker = current_blockers[blocker_id]
          subscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker)
        end)

      state =
        Enum.reduce(removed_blocker_ids, state, fn blocker_id, state_acc ->
          blocker = previous_blockers[blocker_id]
          # The resume stays outside the gating helper on purpose. #1821 made a
          # cleared dependency wake its blockee; putting that behind a failed
          # unsubscribe RPC would reintroduce exactly the stall it fixed. Only
          # the derived event is deferred to the next reconcile.
          state_acc
          |> unsubscribe_and_maybe_enqueue_dependency(issue, blocker)
          |> PushRouting.maybe_resume_blockee_on_cleared_dependency(issue, blocker, :removed)
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

  def emit_dependency_transition_events(%State{} = state, _previous_issue, _issue, _opts), do: state

  # Compares against the labels the tracker reported, so a restart (no previous
  # issue) writes only where the label is wrong and a stale label heals.
  defp sync_dependency_reason_label(state, _previous_issue, issue, opts) do
    current_open? = open_dependency?(issue)
    labeled? = "#{Config.label_prefix()}:blocked" in Enum.map(List.wrap(issue.labels), &String.downcase/1)

    if is_nil(current_open?) or current_open? == labeled? do
      state
    else
      schedule_dependency_reason_label(state, issue, current_open?, opts)
    end
  end

  defp schedule_dependency_reason_label(state, issue, current_open?, opts) do
    action = if current_open?, do: :add, else: :remove
    writer = Keyword.get(opts, :reason_label_writer, &write_dependency_reason_label/2)

    TrackerTasks.chain(
      state,
      {:runtime_reason_labels, issue.identifier},
      fn -> writer.(issue.identifier, action) end,
      &apply_dependency_label_result(&1, &2, issue.identifier)
    )
  end

  defp apply_dependency_label_result(state, :ok, _identifier), do: state

  defp apply_dependency_label_result(state, {:error, reason}, identifier) do
    Logger.warning("blocked reason label update failed: issue=#{identifier} reason=#{inspect(reason)}")
    state
  end

  defp open_dependency?(%Issue{blocked_by: []}), do: false

  defp open_dependency?(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: state} when is_binary(state) -> not DispatchPolicy.terminal_issue_state?(state, DispatchPolicy.terminal_state_set())
      _unknown -> true
    end)
  end

  defp open_dependency?(%Issue{blocked_by: blockers}) when is_nil(blockers), do: nil
  defp open_dependency?(_issue), do: nil

  defp write_dependency_reason_label(identifier, action),
    do: TicketTransition.write_reason_modifier(identifier, action, "blocked", writer: :issue_sync_dependencies)

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

  defp unsubscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker) do
    reconcile_dependency_subscription(state_acc, issue, blocker, :dependency_removed, &AutoSubscriptions.auto_unsubscribe_for_dependency/2)
  end

  defp subscribe_and_maybe_enqueue_dependency(state_acc, issue, blocker) do
    reconcile_dependency_subscription(state_acc, issue, blocker, :dependency_added, &AutoSubscriptions.auto_subscribe_for_dependency/2)
  end

  defp reconcile_dependency_subscription(state, issue, blocker, event_type, mutation) do
    apply_result = fn current, result ->
      case result do
        :ok ->
          enqueue_dependency_event(current, issue, blocker, event_type)

        {:error, reason} ->
          blocker_id = blocker["identifier"] || Map.get(blocker, :identifier)

          Logger.warning(
            "IssueSync: dependency subscription mutation failed for #{event_type} " <>
              "(#{issue.identifier}, blocker #{blocker_id}): #{inspect(reason)}; event will emit on next reconcile"
          )

          current
      end
    end

    TrackerTasks.chain(state, {:dependency_subscription, issue.id, blocker[:id]}, fn -> mutation.(issue, blocker) end, apply_result)
  end

  # Public because `PushRouting` enqueues a `:blocker_became_terminal` event
  # through it; keep it exported even though this module is its main caller.
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
        OperatorMessages.notify_running_queue_update(state, running_entry, item)
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

  @doc false
  @spec sync_dependency_circular_wait_alert(State.t(), list(), integer()) :: State.t()
  def sync_dependency_circular_wait_alert(%State{} = state, issues, now_ms)
      when is_list(issues) and is_integer(now_ms) do
    if circular_wait_detection_enabled?(state) do
      waits = dependency_circular_waits(state, issues)

      resolve_dependency_circular_waits(state.dependency_circular_wait, waits)

      next_waits =
        waits
        |> Map.values()
        |> Enum.sort_by(& &1.identifier)
        |> Enum.reduce(%{}, fn wait, next ->
          previous = Map.get(state.dependency_circular_wait, wait.id)
          entry = update_dependency_circular_wait(previous, wait, now_ms)
          Map.put(next, wait.id, entry)
        end)

      %{state | dependency_circular_wait: next_waits}
    else
      state
    end
  end

  def sync_dependency_circular_wait_alert(%State{} = state, _issues, _now_ms), do: state

  @spec sync_dependency_circular_wait_alert(State.t(), list()) :: State.t()
  def sync_dependency_circular_wait_alert(%State{} = state, issues) when is_list(issues),
    do: sync_dependency_circular_wait_alert(state, issues, System.monotonic_time(:millisecond))

  def sync_dependency_circular_wait_alert(%State{} = state, _issues), do: state

  defp dependency_circular_waits(state, issues) do
    waiters_by_blocker = dependency_waiters_by_blocker(state.running)

    Enum.reduce(issues, %{}, fn
      %Issue{id: id, identifier: identifier} = issue, waits when is_binary(id) and is_binary(identifier) ->
        waiting_count = Map.get(waiters_by_blocker, identifier, 0)

        if waiting_count > 0 and queued_undispatched?(issue, state) do
          Map.put(waits, id, %{id: id, identifier: identifier, waiting_count: waiting_count})
        else
          waits
        end

      _issue, waits ->
        waits
    end)
  end

  # DispatchPolicy only evaluates static ticket and slot eligibility. During a
  # global pause, prewarm hold, or host-pressure hold it can still describe a
  # queued ticket as dispatchable even though the dispatcher deliberately did
  # not attempt it. Those expected holds are not dependency cycles.
  defp circular_wait_detection_enabled?(%State{globally_paused: true}), do: false
  defp circular_wait_detection_enabled?(%State{capacity_hold: hold}) when not is_nil(hold), do: false
  defp circular_wait_detection_enabled?(%State{prewarm_hold_ticks: ticks}) when is_integer(ticks) and ticks > 0, do: false
  defp circular_wait_detection_enabled?(%State{}), do: true

  defp dependency_waiters_by_blocker(running) do
    Enum.reduce(running, %{}, fn
      {_issue_id, %{paused_reason: :blocker_dependency, blocker_pause: %{blocker_identifier: identifier}}}, waiters
      when is_binary(identifier) and identifier != "" ->
        Map.update(waiters, identifier, 1, &(&1 + 1))

      _running, waiters ->
        waiters
    end)
  end

  defp queued_undispatched?(%Issue{} = issue, state) do
    DispatchPolicy.dispatch_decision(issue, state) in [:dispatch, {:skip, :fleet_capacity}]
  end

  defp update_dependency_circular_wait(previous, wait, now_ms) do
    since_ms = if is_map(previous), do: previous.since_ms, else: now_ms
    alerted? = is_map(previous) and previous.alerted? == true
    entry = Map.merge(wait, %{since_ms: since_ms, alerted?: alerted?})

    if alerted? or now_ms - since_ms < @capacity_starvation_alert_after_ms do
      entry
    else
      emit_dependency_circular_wait(entry)
    end
  end

  defp emit_dependency_circular_wait(entry) do
    topic = dependency_circular_wait_topic(entry.identifier)
    message = "Circular wait: #{entry.identifier} is queued while #{entry.waiting_count} parked agent(s) wait on it."

    case Alerts.emit_system(topic,
           message: message,
           issue: entry.identifier,
           reason: message,
           needs_attention: true,
           severity: "warning"
         ) do
      :ok -> %{entry | alerted?: true}
      {:error, _reason} -> entry
    end
  end

  defp resolve_dependency_circular_waits(previous_waits, current_waits) do
    previous_waits
    |> Map.reject(fn {id, _entry} -> Map.has_key?(current_waits, id) end)
    |> Map.values()
    |> Enum.filter(&(&1.alerted? == true))
    |> Enum.each(fn entry ->
      message = "Circular wait cleared for #{entry.identifier}."

      Alerts.emit_system(dependency_circular_wait_topic(entry.identifier) <> ".resolved",
        message: message,
        issue: entry.identifier,
        reason: message,
        needs_attention: false,
        severity: "info"
      )
    end)
  end

  defp dependency_circular_wait_topic(identifier),
    do: "ticket.#{identifier}.agent.attention.dependency-circular-wait"
end
