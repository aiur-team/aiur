defmodule Aiur.Orchestrator.OperatorMessages.Calls do
  @moduledoc """
  Orchestrator-side `*_call` handlers for the operator-message and queue control API.
  Public API stays on `Aiur.Orchestrator.OperatorMessages`.
  """

  import Aiur.Orchestrator.OperatorMessages.Capabilities, only: [issue_control_capabilities: 2]
  import Aiur.Orchestrator.OperatorMessages.Enqueue, only: [enqueue_event_digest_item: 4, enqueue_event_digest_item: 5, enqueue_operator_message: 4, enqueue_operator_message: 5]

  alias Aiur.{AgentEvents, AgentPubSub, AgentQueueStore, Alerts, Commands, OperatorWaitLog, TrackerIdentity}
  alias Aiur.Orchestrator.{AutoSubscriptions, DigestCoalescer, LifecycleFence, State}

  @spec enqueue_event_digest_call(State.t(), String.t(), map(), keyword()) ::
          {:reply, :ok, State.t()}
  def enqueue_event_digest_call(%State{} = state, identifier, event, opts \\ []) do
    {:reply, :ok, enqueue_event_digest_item(state, identifier, [event], event, opts)}
  end

  @spec enqueue_event_digest_batch_call(State.t(), String.t(), [map()]) ::
          {:reply, :ok, State.t()}
  def enqueue_event_digest_batch_call(%State{} = state, identifier, events)
      when is_binary(identifier) and is_list(events) do
    {:reply, :ok, enqueue_event_digest_item(state, identifier, events, %{events: events})}
  end

  @spec send_operator_message_call(State.t(), String.t(), map()) ::
          {:reply, {:ok, integer()} | {:error, term()}, State.t()}
  def send_operator_message_call(
        %State{} = state,
        issue_identifier,
        %{kind: :text, body: body} = payload
      )
      when is_binary(issue_identifier) and is_binary(body) do
    {reply, next_state} = enqueue_operator_message(state, issue_identifier, body, payload)
    {:reply, reply, next_state}
  end

  def send_operator_message_call(%State{} = state, %TrackerIdentity{} = identity, payload) do
    case State.find_unique_running_by_identity(state.running, identity) do
      {:ok, _entry, issue_identifier} -> send_operator_message_call(state, issue_identifier, payload)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def send_operator_message_call(%State{} = state, _issue_identifier, _payload) do
    {:reply, {:error, :invalid_message}, state}
  end

  @spec send_correlated_operator_message_call(State.t(), String.t(), map()) ::
          {:reply, {:ok, map()} | {:error, term()}, State.t()}
  def send_correlated_operator_message_call(
        %State{} = state,
        issue_identifier,
        %{kind: :text, body: body, action_id: action_id, correlation: correlation} = payload
      )
      when is_binary(issue_identifier) and is_binary(body) and is_binary(action_id) and is_map(correlation) do
    if correlation_action_id(correlation) == action_id do
      {reply, next_state} = enqueue_operator_message(state, issue_identifier, body, payload, :correlated)
      {:reply, reply, next_state}
    else
      {:reply, {:error, :action_mismatch}, state}
    end
  end

  def send_correlated_operator_message_call(%State{} = state, _issue_identifier, _payload) do
    {:reply, {:error, :invalid_message}, state}
  end

  @spec control_capabilities_call(State.t(), String.t()) :: {:reply, {:ok, map()}, State.t()}
  def control_capabilities_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    {:reply, {:ok, issue_control_capabilities(state, issue_identifier)}, state}
  end

  @spec claim_next_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  def claim_next_queue_item_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    {state, queue_store, item} = claim_resume_input(state, issue_identifier)

    {queue_store, item} = maybe_coalesce_events(queue_store, issue_identifier, item)
    queue_claim_reply(state, queue_store, item)
  end

  defp claim_resume_input(state, identifier) do
    entry = State.find_running_by_identifier(state.running, identifier)
    item_id = if entry, do: Map.get(entry, :resume_input_id)

    {store, item} =
      AgentQueueStore.claim_next_deliverable_matching(state.queue_store, identifier, &(&1.id == item_id))

    state = clear_resume_input(state, entry)

    if item do
      {state, store, item}
    else
      {store, item} = AgentQueueStore.claim_next_deliverable(store, identifier)
      {state, store, item}
    end
  end

  defp clear_resume_input(state, %{issue: %{id: id}} = entry),
    do: %{state | running: Map.put(state.running, id, Map.delete(entry, :resume_input_id))}

  defp clear_resume_input(state, _entry), do: state

  @spec claim_next_checkpoint_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  def claim_next_checkpoint_queue_item_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        fn item -> item.delivery[:interrupt_requested] != true end
      )

    queue_claim_reply(state, queue_store, item)
  end

  @spec claim_blocker_critical_events_digest_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  def claim_blocker_critical_events_digest_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    direct_blockers = AutoSubscriptions.direct_blockers_for(state, issue_identifier)

    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        &AutoSubscriptions.blocker_critical_digest?(&1, direct_blockers)
      )

    queue_claim_reply(state, queue_store, item)
  end

  @spec claim_next_operator_queue_item_call(State.t(), String.t()) ::
          {:reply, :empty | {:ok, map()}, State.t()}
  def claim_next_operator_queue_item_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable_matching(
        state.queue_store,
        issue_identifier,
        &match?(%{category: :operator_message}, &1)
      )

    queue_claim_reply(state, queue_store, item)
  end

  @spec claim_operator_response_call(State.t(), String.t(), String.t()) :: tuple()
  def claim_operator_response_call(state, identifier, command) do
    {store, item} =
      AgentQueueStore.claim_next_deliverable_matching(state.queue_store, identifier, fn
        %{category: :operator_message, body: %{text: text}} when is_binary(text) ->
          List.first(String.split(String.trim(text), ~r/\s+/, parts: 2)) == command

        _ ->
          false
      end)

    queue_claim_reply(state, store, item)
  end

  @spec operator_message_status_call(State.t(), integer()) ::
          {:reply, {:ok, Aiur.AgentQueueItem.status()} | {:error, :unknown_message}, State.t()}
  def operator_message_status_call(%State{} = state, item_id) when is_integer(item_id) do
    case AgentQueueStore.get(state.queue_store, item_id) do
      nil -> {:reply, {:error, :unknown_message}, state}
      item -> {:reply, {:ok, item.status}, state}
    end
  end

  @doc "Find the queue item a keyed send created: by message id, or by decision action id."
  @spec lookup_operator_message_call(State.t(), {:message_id | :action_id, String.t()}) ::
          {:reply, {:ok, Aiur.AgentQueueItem.t()} | {:error, :unknown_message}, State.t()}
  def lookup_operator_message_call(%State{} = state, {kind, key}) when is_binary(key) do
    item =
      case kind do
        :message_id -> AgentQueueStore.find_by_message_id(state.queue_store, key)
        :action_id -> AgentQueueStore.find_by_action(state.queue_store, key)
      end

    case item do
      nil -> {:reply, {:error, :unknown_message}, state}
      item -> {:reply, {:ok, item}, state}
    end
  end

  @doc """
  Find the item a keyed plain send created, and check it is that send: the
  same target and text. An id reused for other text is a conflict (#2717).

  """
  @spec lookup_operator_message_call(State.t(), {:message_id, String.t()}, %{target: term(), text: String.t()}) ::
          {:reply, {:ok, Aiur.AgentQueueItem.t()} | {:error, term()}, State.t()}
  def lookup_operator_message_call(%State{} = state, {:message_id, _key} = lookup, %{target: target, text: text}) do
    case lookup_operator_message_call(state, lookup) do
      {:reply, {:ok, item}, state} ->
        expected = %{target_issue_identifier: lookup_target(state, target), body: %{text: String.trim(text)}}

        if AgentQueueStore.same_message?(item, expected),
          do: {:reply, {:ok, item}, state},
          else: {:reply, {:error, {:message_id_conflict, item.id}}, state}

      reply ->
        reply
    end
  end

  defp lookup_target(_state, target) when is_binary(target), do: target

  defp lookup_target(state, %TrackerIdentity{} = identity) do
    case State.find_unique_running_by_identity(state.running, identity) do
      {:ok, _entry, issue_identifier} -> issue_identifier
      {:error, _reason} -> identity.identifier
    end
  end

  @spec mark_queue_item_consumed_call(State.t(), integer()) :: {:reply, :ok, State.t()}
  def mark_queue_item_consumed_call(%State{} = state, item_id) when is_integer(item_id) do
    update_queue_store(state, &AgentQueueStore.mark_consumed(&1, item_id), :consumed)
  end

  @spec restore_queue_item_pending_call(State.t(), integer()) :: {:reply, :ok, State.t()}
  def restore_queue_item_pending_call(%State{} = state, item_id) when is_integer(item_id) do
    update_queue_store(state, &AgentQueueStore.restore_pending(&1, item_id), :restored)
  end

  @spec mark_queue_item_failed_call(State.t(), integer(), term()) :: {:reply, :ok, State.t()}
  def mark_queue_item_failed_call(%State{} = state, item_id, reason) when is_integer(item_id) do
    update_queue_store(state, &AgentQueueStore.mark_failed(&1, item_id, reason), :failed, reason)
  end

  @spec acknowledge_queue_item_delivery_call(State.t(), integer(), map()) ::
          {:reply, :ok, State.t()}
  def acknowledge_queue_item_delivery_call(%State{} = state, item_id, provider_metadata)
      when is_integer(item_id) and is_map(provider_metadata) do
    previous_item = AgentQueueStore.get(state.queue_store, item_id)

    {queue_store, item} =
      AgentQueueStore.mark_provider_delivered(
        state.queue_store,
        item_id,
        provider_metadata
      )

    next_state = %{state | queue_store: queue_store}

    if newly_provider_delivered?(previous_item, item) do
      record_provider_delivery_evidence(item)
      {:reply, :ok, LifecycleFence.acknowledge_provider_delivery(next_state, item)}
    else
      {:reply, :ok, next_state}
    end
  end

  @spec consume_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  def consume_delivered_queue_items_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.consume_delivered(&1, issue_identifier), :consumed)
  end

  @spec restore_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  def restore_delivered_queue_items_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.restore_delivered(&1, issue_identifier), :restored)
  end

  @spec fail_delivered_queue_items_call(State.t(), String.t(), term()) ::
          {:reply, :ok, State.t()}
  def fail_delivered_queue_items_call(%State{} = state, issue_identifier, reason)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.fail_delivered(&1, issue_identifier, reason), :failed, reason)
  end

  @doc false
  @spec coalesce_for_test(AgentQueueStore.t(), String.t()) ::
          {AgentQueueStore.t(), map() | nil}
  def coalesce_for_test(queue_store, issue_identifier) when is_binary(issue_identifier) do
    {queue_store, item} = AgentQueueStore.claim_next_deliverable(queue_store, issue_identifier)
    maybe_coalesce_events(queue_store, issue_identifier, item)
  end

  defp maybe_coalesce_events(
         queue_store,
         issue_identifier,
         %{category: :coordination_event, event_type: :events_digest} = item
       ) do
    DigestCoalescer.coalesce_events_digests(queue_store, issue_identifier, item)
  end

  defp maybe_coalesce_events(queue_store, _issue_identifier, item),
    do: {queue_store, item}

  defp queue_claim_reply(state, queue_store, item) do
    reply = if is_nil(item), do: :empty, else: {:ok, item}
    {:reply, reply, %{state | queue_store: queue_store}}
  end

  defp update_queue_store(%State{} = state, update, transition, reason \\ nil) when is_function(update, 1) do
    {queue_store, items} = update.(state.queue_store)
    Commands.record_transport_batch_async(transition, List.wrap(items), reason)
    next_state = %{state | queue_store: queue_store}
    maybe_alert_failed_fenced_items(next_state, transition, List.wrap(items), reason)
    {:reply, :ok, next_state}
  end

  defp newly_provider_delivered?(
         %{provider_delivered_at: nil},
         %{provider_delivered_at: %DateTime{}}
       ),
       do: true

  defp newly_provider_delivered?(_previous_item, _item), do: false

  defp record_provider_delivery_evidence(
         %{
           category: :operator_message,
           id: request_id,
           target_issue_identifier: identifier
         } = item
       ) do
    OperatorWaitLog.record_delivered(request_id, identifier)

    AgentPubSub.broadcast_transcript(
      identifier,
      AgentEvents.transcript_event(
        :system,
        "Executor message delivered to provider (request_id=#{request_id})",
        payload: %{
          operator_message: %{
            request_id: request_id,
            status: :delivered,
            provider_turn_id: item.provider_turn_id,
            provider_delivered_at: item.provider_delivered_at
          }
        }
      )
    )
  end

  defp record_provider_delivery_evidence(_item), do: :ok

  defp maybe_alert_failed_fenced_items(state, :failed, items, reason) do
    Enum.each(items, fn item ->
      if LifecycleFence.protected_item?(state, item) do
        identifier = item.target_issue_identifier

        Alerts.emit_system("ticket.#{identifier}.agent.provider_delivery_failed",
          issue: identifier,
          reason: "Authoritative input request #{item.id} failed before provider acknowledgement and still fences lifecycle handoff: #{inspect(reason)}.",
          needs_attention: true,
          severity: "warning"
        )
      end
    end)
  end

  defp maybe_alert_failed_fenced_items(_state, _transition, _items, _reason), do: :ok

  defp correlation_action_id(correlation) do
    Map.get(correlation, :action_id, Map.get(correlation, "action_id"))
  end
end
