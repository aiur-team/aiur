defmodule Aiur.Orchestrator.OperatorMessages.Enqueue do
  @moduledoc """
  Validates, dedupes, and queues Executor messages and event digests for a running agent.
  Public API stays on `Aiur.Orchestrator.OperatorMessages`.
  """

  @max_operator_message_chars 8_000

  alias Aiur.{AgentEvents, AgentPubSub, AgentQueue, AgentQueueStore, OperatorWaitLog}
  alias Aiur.Orchestrator.{AutoSubscriptions, CommentWake, LifecycleFence, PauseResume, State}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}

  @doc false
  @spec payload_key(map(), term()) :: String.t() | nil
  def payload_key(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map(), keyword()) :: State.t()
  def enqueue_event_digest_item(%State{} = state, identifier, events, _summary_source, opts \\ [])
      when is_binary(identifier) and is_list(events) and is_list(opts) do
    events = reject_already_queued_events(state.queue_store, events)

    if events == [] do
      state
    else
      do_enqueue_event_digest_item(state, identifier, events, Keyword.get(opts, :subscribed_to))
    end
  end

  defp do_enqueue_event_digest_item(state, identifier, events, subscribed_to) do
    summary_source = if length(events) == 1, do: List.first(events), else: %{events: events}

    blocker_critical? = blocker_critical_events?(state, identifier, events, subscribed_to)

    body = %{
      summary: CommentWake.event_digest_summary(summary_source),
      events: events,
      urgent: blocker_critical?
    }

    running_entry = State.find_running_by_identifier(state.running, identifier)
    delivery_opts = DeliveryPolicy.event_digest_delivery_opts(running_entry, events, blocker_critical?)

    {queue_store, item} =
      AgentQueue.coordination_event(identifier, :events_digest, body, delivery_opts)
      |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

    next_state =
      state
      |> Map.put(:queue_store, queue_store)
      |> maybe_replace_completed_runner(running_entry)
      |> LifecycleFence.protect_queued_item(identifier, item)

    case running_entry do
      nil ->
        :ok

      running_entry ->
        DeliveryPolicy.notify_running_queue_update(state, running_entry, item)
    end

    next_state
  end

  defp blocker_critical_events?(state, identifier, events, subscribed_to) do
    direct_blockers = AutoSubscriptions.direct_blockers_for(state, identifier, subscribed_to)

    AutoSubscriptions.blocker_critical_digest?(
      %{category: :coordination_event, event_type: :events_digest, body: %{events: events}},
      direct_blockers
    )
  end

  # Deduplicate synchronous CI wakes and asynchronous exchange copies, even
  # after the original item was delivered or consumed.
  defp reject_already_queued_events(%AgentQueueStore{} = queue_store, events) do
    known_ids =
      queue_store.items
      |> Map.values()
      |> Enum.flat_map(&queued_event_ids/1)
      |> MapSet.new()

    Enum.reject(events, fn event ->
      case event_id(event) do
        id when is_integer(id) -> MapSet.member?(known_ids, id)
        _ -> false
      end
    end)
  end

  defp queued_event_ids(%{
         category: :coordination_event,
         event_type: :events_digest,
         body: %{events: queued}
       }) do
    Enum.flat_map(List.wrap(queued), &event_id_list/1)
  end

  defp queued_event_ids(_item), do: []

  defp event_id_list(event) do
    case event_id(event) do
      id when is_integer(id) -> [id]
      _ -> []
    end
  end

  defp event_id(event) when is_map(event), do: Map.get(event, :id) || Map.get(event, "id")

  defp event_id(_event), do: nil

  @spec enqueue_operator_message(State.t(), String.t(), String.t(), map(), :plain | :correlated) ::
          {{:ok, integer() | map()} | {:error, term()}, State.t()}
  def enqueue_operator_message(state, issue_identifier, body, payload, mode \\ :plain) do
    request = %{
      delivery_policy: Map.get(payload, :delivery_policy, :checkpoint),
      fallback: Map.get(payload, :fallback),
      turn_id: Map.get(payload, :turn_id),
      action_id: if(mode == :correlated, do: Map.get(payload, :action_id)),
      correlation: if(mode == :correlated, do: Map.get(payload, :correlation)),
      retry_failed: mode == :correlated and Map.get(payload, :retry_failed, false) == true,
      message_id: if(mode == :plain, do: payload_key(payload, :message_id)),
      mode: mode
    }

    case validate_operator_message(body) do
      {:ok, text} ->
        enqueue_validated_operator_message(state, issue_identifier, text, request)

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_validated_operator_message(state, issue_identifier, text, request) do
    case replay_existing_correlated_message(state, issue_identifier, text, request) do
      {:handled, {{:ok, _duplicate}, _replayed_state} = result} ->
        wake_target_for_replayed_message(result, issue_identifier, request)

      {:handled, result} ->
        result

      :continue ->
        case State.find_running_by_identifier(state.running, issue_identifier) do
          nil ->
            {{:error, :no_running_agent}, state}

          running_entry ->
            enqueue_for_running_entry(state, running_entry, issue_identifier, text, request)
        end
    end
  end

  defp replay_existing_correlated_message(
         state,
         issue_identifier,
         text,
         %{mode: :correlated, action_id: action_id} = request
       )
       when is_binary(action_id) do
    case AgentQueueStore.find_by_action(state.queue_store, action_id) do
      nil ->
        :continue

      existing ->
        attrs = %{
          target_issue_identifier: issue_identifier,
          source: existing.source,
          category: existing.category,
          event_type: existing.event_type,
          body: %{text: text},
          delivery: existing.delivery,
          action_id: action_id,
          correlation: request.correlation,
          causal_refs: existing.causal_refs
        }

        case AgentQueueStore.enqueue_correlated(state.queue_store, attrs) do
          {:ok, _queue_store, _item, :duplicate}
          when request.retry_failed and existing.status == :failed ->
            :continue

          {:ok, queue_store, item, :duplicate} ->
            result = {{:ok, %{status: :duplicate, item: item}}, %{state | queue_store: queue_store}}
            {:handled, result}

          {:error, _reason} = error ->
            {:handled, {error, state}}
        end
    end
  end

  # A keyed plain message is idempotent by its message id (#2717): a retry
  # after a caller-side timeout returns the item the first call queued
  # instead of queueing a second copy. The id names one user action, so a
  # different target or text under the same id is refused, never replayed.
  defp replay_existing_correlated_message(state, issue_identifier, text, %{mode: :plain, message_id: message_id})
       when is_binary(message_id) do
    case AgentQueueStore.find_by_message_id(state.queue_store, message_id) do
      nil ->
        :continue

      existing ->
        if AgentQueueStore.same_message?(existing, %{target_issue_identifier: issue_identifier, body: %{text: text}}),
          do: {:handled, {{:ok, existing.id}, state}},
          else: {:handled, {{:error, {:message_id_conflict, existing.id}}, state}}
    end
  end

  defp replay_existing_correlated_message(_state, _issue_identifier, _text, _request),
    do: :continue

  # A correlated answer that resolves to an already-enqueued item short-circuits
  # `enqueue_for_running_entry/5` — and with it the paused-agent wake that path
  # performs. The queue item is a duplicate, but the *work* is not done: the
  # target may have paused again since the first enqueue (an agent that
  # re-raises its Command does exactly this), and nothing else will wake it. The
  # Decision was then recorded queued-and-delivered while the agent sat paused on
  # an answer it never saw, with no failure anywhere for an operator to find
  # (#2558).
  #
  # Idempotent and safe by construction: a correlated message exists only
  # because an answer was durably recorded, so this can never resume an agent
  # whose Decision was not answered; it fires only for an entry that is
  # currently paused; and it routes through `resume_paused_issue/2`, so the
  # active-cap and per-state slot gates are the same ones the explicit operator
  # resume obeys. A refused wake is reported as a delivery failure rather than
  # a silent success, which puts it on `DecisionStore`'s bounded retry ladder.
  defp wake_target_for_replayed_message({reply, state}, issue_identifier, request) do
    with running_entry when is_map(running_entry) <-
           State.find_running_by_identifier(state.running, issue_identifier),
         true <- message_resumes_pause?(state, running_entry, request),
         state = remember_resume_input(state, running_entry, reply),
         {{:ok, :resumed}, resumed_state} <-
           Aiur.Orchestrator.resume_paused_issue(state, running_entry) do
      {reply, resumed_state}
    else
      {{:error, _reason} = error, next_state} -> {error, next_state}
      _not_paused -> {reply, state}
    end
  end

  # Chatting with a paused agent auto-resumes it — but only if a slot is
  # free. Routing through `resume_paused_issue/2` reuses the same
  # active-cap and per-state slot gates as the explicit space-key resume,
  # so we can't push active over max no matter which entry point the
  # Executor uses. If no slot is free, the cap error propagates and the
  # conversation pane surfaces it.
  defp enqueue_for_running_entry(state, running_entry, issue_identifier, text, request) do
    cond do
      State.deactivated_running_entry?(running_entry) ->
        enqueue_after_reactivate(state, running_entry, issue_identifier, text, request)

      message_resumes_pause?(state, running_entry, request) ->
        enqueue_after_resume(state, running_entry, issue_identifier, text, request)

      true ->
        do_enqueue_running_operator_message(state, running_entry, issue_identifier, text, request)
    end
  end

  # A plain operator message resumes any confirmed pause, as before (#2730
  # leaves that path unchanged). A worker's own request for input also ends
  # when the input arrives: a correlated answer or a plain message resumes it,
  # even while the pause is still pending confirmation (control still reports
  # working). Queue the input before superseding that pause, so the resume
  # drains it first. This path never lifts an operator, label, or global hold.
  # A confirmed pause with no recorded reason is a legacy entry; an answer
  # resumed it before #2730 and still does.
  defp message_resumes_pause?(state, entry, request) do
    paused? = State.paused_running_entry?(entry)
    (paused? and request.mode == :plain) or self_pause_ends_on_input?(state, entry, paused?)
  end

  defp self_pause_ends_on_input?(state, entry, true = _paused?) do
    reason = Map.get(entry, :paused_reason)
    (is_nil(reason) or PauseResume.input_pause_reason?(reason)) and no_hold?(state, entry)
  end

  # Only a pause request that is still the current pending control counts. A
  # `pending_pause_reason` left by an expired or rejected request must not
  # turn a message to a working worker into a resume.
  defp self_pause_ends_on_input?(state, entry, false = _paused?),
    do: PauseResume.pending_input_pause?(state, entry) and no_hold?(state, entry)

  defp no_hold?(state, entry),
    do: not state.globally_paused and not Aiur.Issue.paused?(Map.get(entry, :issue))

  # Mirrors `enqueue_after_resume/5` for the `:deactivated → :working`
  # transition. The fresh agent task spawned by `reactivate_issue/2`
  # will pick up the queued Executor message when it boots.
  defp enqueue_after_reactivate(state, running_entry, issue_identifier, text, request) do
    case Aiur.Orchestrator.reactivate_issue(state, running_entry) do
      {{:ok, :reactivated}, next_state} ->
        reactivated_entry = State.find_running_by_identifier(next_state.running, issue_identifier)

        do_enqueue_running_operator_message(next_state, reactivated_entry, issue_identifier, text, request)

      {{:error, _reason} = error, next_state} ->
        {error, next_state}
    end
  end

  defp enqueue_after_resume(state, running_entry, issue_identifier, text, request) do
    with :ok <- PauseResume.resume_paused_issue_preflight(state, running_entry),
         {{:ok, _queued} = queued, queued_state} <-
           do_enqueue_running_operator_message(state, running_entry, issue_identifier, text, request),
         queued_state = remember_resume_input(queued_state, running_entry, queued),
         queued_entry when is_map(queued_entry) <-
           State.find_running_by_identifier(queued_state.running, issue_identifier),
         {{:ok, :resumed}, resumed_state} <-
           Aiur.Orchestrator.resume_paused_issue(queued_state, queued_entry) do
      {queued, resumed_state}
    else
      {:error, reason} -> {{:error, reason}, state}
      {{:error, _reason} = error, next_state} -> {error, next_state}
      _missing_entry -> {{:error, :no_running_agent}, state}
    end
  end

  # A restored interrupted input can precede the answer or message at the same
  # priority. Pin this one resume's first claim without reordering the
  # remaining queue. A correlated answer replies with its item; a plain
  # message replies with its item ID.
  defp remember_resume_input(state, %{issue: %{id: id}}, {:ok, %{item: %{id: item_id, status: :pending}}}) do
    update_in(state.running[id], &Map.put(&1, :resume_input_id, item_id))
  end

  defp remember_resume_input(state, %{issue: %{id: id}}, {:ok, item_id}) when is_integer(item_id) do
    update_in(state.running[id], &Map.put(&1, :resume_input_id, item_id))
  end

  defp remember_resume_input(state, _entry, _reply), do: state

  defp do_enqueue_running_operator_message(state, running_entry, issue_identifier, text, request) do
    capabilities = Capabilities.issue_control_capabilities(state, issue_identifier)

    case DeliveryPolicy.normalize_delivery_request(request.delivery_policy, request.fallback, capabilities) do
      {:ok, queue_opts} ->
        attrs =
          AgentQueue.operator_message(
            issue_identifier,
            text,
            queue_opts
            |> Keyword.put(:turn_id, request.turn_id)
            |> Keyword.put(:action_id, request.action_id)
            |> Keyword.put(:correlation, request.correlation)
          )

        finish_operator_enqueue(state, running_entry, attrs, request)

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp finish_operator_enqueue(state, running_entry, attrs, %{mode: :plain} = request) do
    case enqueue_plain(state.queue_store, attrs, request) do
      {:ok, queue_store, item, :accepted} ->
        record_operator_queued_evidence(item)
        DeliveryPolicy.notify_running_queue_update(state, running_entry, item)

        next_state =
          %{state | queue_store: queue_store}
          |> maybe_replace_completed_runner(running_entry)
          |> LifecycleFence.protect_queued_item(item.target_issue_identifier, item)

        {{:ok, item.id}, next_state}

      {:ok, queue_store, item, :duplicate} ->
        {{:ok, item.id}, %{state | queue_store: queue_store}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp finish_operator_enqueue(state, running_entry, attrs, %{mode: :correlated} = request) do
    case AgentQueueStore.enqueue_correlated(state.queue_store, attrs, retry_failed: request.retry_failed) do
      {:ok, queue_store, item, status} ->
        if status in [:accepted, :retried] do
          record_operator_queued_evidence(item)
          DeliveryPolicy.notify_running_queue_update(state, running_entry, item)
        end

        next_state =
          %{state | queue_store: queue_store}
          |> maybe_replace_completed_runner(running_entry)
          |> maybe_protect_correlated_item(item, status)

        {{:ok, %{status: status, item: item}}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_plain(queue_store, attrs, %{message_id: message_id}) when is_binary(message_id),
    do: AgentQueueStore.enqueue_idempotent(queue_store, Map.put(attrs, :message_id, message_id))

  defp enqueue_plain(queue_store, attrs, _request) do
    {queue_store, item} = AgentQueueStore.enqueue(queue_store, attrs)
    {:ok, queue_store, item, :accepted}
  end

  defp maybe_replace_completed_runner(state, nil), do: state

  defp maybe_replace_completed_runner(state, running_entry) do
    case Map.get(running_entry, :issue) do
      %Aiur.Issue{} = issue -> PauseResume.replace_completed_issue(state, running_entry, issue)
      _ -> state
    end
  end

  defp maybe_protect_correlated_item(state, item, status) when status in [:accepted, :retried],
    do: LifecycleFence.protect_queued_item(state, item.target_issue_identifier, item)

  defp maybe_protect_correlated_item(state, _item, _status), do: state

  defp record_operator_queued_evidence(
         %{
           category: :operator_message,
           id: request_id,
           target_issue_identifier: identifier,
           body: %{text: text}
         } = item
       ) do
    OperatorWaitLog.record_queued(request_id, identifier, byte_size(text))

    AgentPubSub.broadcast_transcript(
      identifier,
      AgentEvents.transcript_event(:user, text,
        turn_id: item.turn_id,
        payload: %{
          operator_message:
            %{request_id: request_id, status: :queued}
            |> put_decision_id(item)
        }
      )
    )
  end

  # The echo is written when the message is queued, not when the agent gets
  # it, so the ticket log labels it with its queue item and, for a Decision
  # answer, the decision id (#2717). Delivery is logged separately below.
  defp put_decision_id(evidence, %{correlation: correlation}) when is_map(correlation) do
    case Map.get(correlation, :decision_id, Map.get(correlation, "decision_id")) do
      decision_id when is_binary(decision_id) -> Map.put(evidence, :decision_id, decision_id)
      _other -> evidence
    end
  end

  defp put_decision_id(evidence, _item), do: evidence

  defp validate_operator_message(body) do
    text = String.trim(body)

    cond do
      text == "" -> {:error, :empty_message}
      String.length(text) > @max_operator_message_chars -> {:error, :message_too_long}
      true -> {:ok, text}
    end
  end
end
