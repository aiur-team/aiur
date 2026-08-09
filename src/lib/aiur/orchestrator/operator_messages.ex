defmodule Aiur.Orchestrator.OperatorMessages do
  @moduledoc """
  Queues and routes Executor messages and event digests to running agents. All functions execute inside the orchestrator GenServer process.
  """
  alias Aiur.{AgentEvents, AgentPubSub, AgentQueue, AgentQueueStore, Alerts, OperatorWaitLog, TrackerIdentity}

  alias Aiur.Orchestrator.{
    AutoSubscriptions,
    CommentWake,
    DigestCoalescer,
    LifecycleFence,
    PauseResume,
    State
  }

  alias Aiur.Orchestrator.StatusReason

  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}
  @max_operator_message_chars 8_000

  @spec send_operator_message(String.t() | TrackerIdentity.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(issue_identifier, payload),
    do: send_operator_message(Aiur.Orchestrator, issue_identifier, payload)

  @spec send_operator_message(GenServer.server(), String.t() | TrackerIdentity.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, issue_identifier, payload),
    do: control_api_call(server, {:send_operator_message, issue_identifier, payload}, 5_000)

  @doc "Send one idempotent action-correlated Executor message and return its queue snapshot."
  @spec send_correlated_operator_message(String.t(), map()) ::
          {:ok, %{status: :accepted | :duplicate | :retried, item: Aiur.AgentQueueItem.t()}}
          | {:error, term()}
  def send_correlated_operator_message(issue_identifier, payload),
    do: send_correlated_operator_message(Aiur.Orchestrator, issue_identifier, payload)

  @spec send_correlated_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, %{status: :accepted | :duplicate | :retried, item: Aiur.AgentQueueItem.t()}}
          | {:error, term()}
  def send_correlated_operator_message(server, issue_identifier, payload),
    do: control_api_call(server, {:send_correlated_operator_message, issue_identifier, payload}, 5_000)

  @spec control_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def control_capabilities(issue_identifier),
    do: control_capabilities(Aiur.Orchestrator, issue_identifier)

  @spec control_capabilities(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def control_capabilities(server, issue_identifier) when is_binary(issue_identifier),
    do: control_api_call(server, {:control_capabilities, issue_identifier}, 5_000)

  @spec claim_next_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_queue_item(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:claim_next_queue_item, issue_identifier})

  @spec claim_next_checkpoint_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_checkpoint_queue_item(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_next_checkpoint_queue_item, issue_identifier})

  @spec claim_blocker_critical_events_digest(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_blocker_critical_events_digest(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_blocker_critical_events_digest, issue_identifier})

  @spec claim_next_operator_queue_item(GenServer.server(), String.t()) ::
          {:ok, map()} | :empty | {:error, term()}
  def claim_next_operator_queue_item(server, issue_identifier)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:claim_next_operator_queue_item, issue_identifier})

  @spec mark_queue_item_consumed(GenServer.server(), integer()) :: :ok | {:error, term()}
  def mark_queue_item_consumed(server, item_id) when is_integer(item_id),
    do: queue_api_call(server, {:mark_queue_item_consumed, item_id})

  @spec restore_queue_item_pending(GenServer.server(), integer()) :: :ok | {:error, term()}
  def restore_queue_item_pending(server, item_id) when is_integer(item_id),
    do: queue_api_call(server, {:restore_queue_item_pending, item_id})

  @spec mark_queue_item_failed(GenServer.server(), integer(), term()) ::
          :ok | {:error, term()}
  def mark_queue_item_failed(server, item_id, reason) when is_integer(item_id),
    do: queue_api_call(server, {:mark_queue_item_failed, item_id, reason})

  @spec acknowledge_queue_item_delivery(GenServer.server(), integer(), map()) ::
          :ok | {:error, term()}
  def acknowledge_queue_item_delivery(server, item_id, provider_metadata)
      when is_integer(item_id) and is_map(provider_metadata),
      do:
        queue_api_call(
          server,
          {:acknowledge_queue_item_delivery, item_id, provider_metadata}
        )

  @spec consume_delivered_queue_items(GenServer.server(), String.t()) ::
          :ok | {:error, term()}
  def consume_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:consume_delivered_queue_items, issue_identifier})

  @spec restore_delivered_queue_items(GenServer.server(), String.t()) ::
          :ok | {:error, term()}
  def restore_delivered_queue_items(server, issue_identifier) when is_binary(issue_identifier),
    do: queue_api_call(server, {:restore_delivered_queue_items, issue_identifier})

  @spec fail_delivered_queue_items(GenServer.server(), String.t(), term()) ::
          :ok | {:error, term()}
  def fail_delivered_queue_items(server, issue_identifier, reason)
      when is_binary(issue_identifier),
      do: queue_api_call(server, {:fail_delivered_queue_items, issue_identifier, reason})

  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map()) :: State.t()
  def enqueue_event_digest_item(%State{} = state, identifier, events, _summary_source)
      when is_binary(identifier) and is_list(events) do
    events = reject_already_queued_events(state.queue_store, events)

    if events == [] do
      state
    else
      do_enqueue_event_digest_item(state, identifier, events)
    end
  end

  defp do_enqueue_event_digest_item(state, identifier, events) do
    summary_source = if length(events) == 1, do: List.first(events), else: %{events: events}

    blocker_critical? = blocker_critical_events?(state, identifier, events)

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
      |> LifecycleFence.protect_queued_item(identifier, item)

    case running_entry do
      nil ->
        :ok

      running_entry ->
        DeliveryPolicy.notify_running_queue_update(running_entry, item)
    end

    next_state
  end

  defp blocker_critical_events?(state, identifier, events) do
    direct_blockers = AutoSubscriptions.direct_blockers_for(state, identifier)

    AutoSubscriptions.blocker_critical_digest?(
      %{category: :coordination_event, event_type: :events_digest, body: %{events: events}},
      direct_blockers
    )
  end

  # The orchestrator may queue a terminal CI event synchronously before it
  # resumes a runner, while the durable SubscriptionStore delivers the same
  # exchange event asynchronously. Keep one queue item even if the second copy
  # arrives after the first was already delivered or consumed.
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

  @spec enqueue_event_digest_call(State.t(), String.t(), map()) ::
          {:reply, :ok, State.t()}
  def enqueue_event_digest_call(%State{} = state, identifier, event) do
    {:reply, :ok, enqueue_event_digest_item(state, identifier, [event], event)}
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
    {queue_store, item} =
      AgentQueueStore.claim_next_deliverable(state.queue_store, issue_identifier)

    {queue_store, item} = maybe_coalesce_events(queue_store, issue_identifier, item)
    queue_claim_reply(state, queue_store, item)
  end

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

  defp replay_existing_correlated_message(_state, _issue_identifier, _text, _request),
    do: :continue

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

      State.paused_running_entry?(running_entry) ->
        enqueue_after_resume(state, running_entry, issue_identifier, text, request)

      true ->
        do_enqueue_running_operator_message(state, running_entry, issue_identifier, text, request)
    end
  end

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

  defp finish_operator_enqueue(state, running_entry, attrs, %{mode: :plain}) do
    {queue_store, item} = AgentQueueStore.enqueue(state.queue_store, attrs)
    record_operator_queued_evidence(item)
    DeliveryPolicy.notify_running_queue_update(running_entry, item)

    next_state =
      %{state | queue_store: queue_store}
      |> maybe_replace_completed_runner(running_entry)
      |> LifecycleFence.protect_queued_item(item.target_issue_identifier, item)

    {{:ok, item.id}, next_state}
  end

  defp finish_operator_enqueue(state, running_entry, attrs, %{mode: :correlated} = request) do
    case AgentQueueStore.enqueue_correlated(state.queue_store, attrs, retry_failed: request.retry_failed) do
      {:ok, queue_store, item, status} ->
        if status in [:accepted, :retried] do
          record_operator_queued_evidence(item)
          DeliveryPolicy.notify_running_queue_update(running_entry, item)
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

  defp maybe_replace_completed_runner(state, running_entry) do
    case Map.get(running_entry, :issue) do
      %Aiur.Issue{} = issue -> PauseResume.replace_completed_issue(state, running_entry, issue)
      _ -> state
    end
  end

  defp maybe_protect_correlated_item(state, item, status) when status in [:accepted, :retried],
    do: LifecycleFence.protect_queued_item(state, item.target_issue_identifier, item)

  defp maybe_protect_correlated_item(state, _item, _status), do: state

  @spec maybe_emit_agent_control_alert(atom(), atom(), map()) :: :ok
  def maybe_emit_agent_control_alert(previous_status, status, running_entry) do
    maybe_emit_agent_control_alert(previous_status, status, running_entry, Map.get(running_entry, :paused_reason))
  end

  @spec maybe_emit_agent_control_alert(atom(), atom(), map(), atom() | String.t() | nil) :: :ok
  def maybe_emit_agent_control_alert(
        :working,
        :paused,
        %{paused_reason: :ci_wait} = running_entry,
        _previous_pause_reason
      )
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.ci.wait",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Waiting for CI before human review.",
      needs_attention: false,
      severity: "info"
    )
  end

  def maybe_emit_agent_control_alert(:working, :paused, running_entry, _previous_pause_reason)
      when is_map(running_entry) do
    pause_reason = Map.get(running_entry, :paused_reason)
    reason = StatusReason.render(StatusReason.for_pause(pause_reason))

    Alerts.emit_system(pause_attention_topic(running_entry, pause_reason),
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent paused (#{reason}); expected to clear #{pause_clearance(pause_reason)}.",
      needs_attention: true,
      severity: "warning"
    )
  end

  def maybe_emit_agent_control_alert(:paused, :working, running_entry, previous_pause_reason)
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.unpaused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent resumed; no Executor action is needed.",
      needs_attention: false,
      severity: "info"
    )

    if is_nil(previous_pause_reason) do
      :ok
    else
      Alerts.emit_system("#{pause_attention_topic(running_entry, previous_pause_reason)}.resolved",
        issue: Map.get(running_entry, :identifier),
        workspace: Map.get(running_entry, :workspace_path),
        worker_host: Map.get(running_entry, :worker_host),
        reason: "Agent pause cause #{pause_cause(previous_pause_reason)} is resolved.",
        needs_attention: false,
        severity: "info"
      )
    end
  end

  def maybe_emit_agent_control_alert(_previous_status, _status, _running_entry, _previous_pause_reason), do: :ok

  defp pause_attention_topic(running_entry, pause_reason) do
    "ticket.#{Map.get(running_entry, :identifier)}.agent.attention.paused-#{pause_cause(pause_reason)}"
  end

  defp pause_cause(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp pause_cause(reason) when is_binary(reason) and reason != "" do
    if Regex.match?(~r/\A[a-z0-9_-]+\z/, reason), do: reason, else: "unknown"
  end

  defp pause_cause(_reason), do: "unknown"

  defp pause_clearance(reason) when reason in [:operator_pause, :label_override, :agent_pause_request, :input_required, :blocker_dependency],
    do: "after Executor or agent action"

  defp pause_clearance(reason) when reason in [:global_pause, :usage_limit_exhausted], do: "when the condition is lifted"
  defp pause_clearance(:before_run_failure), do: "after preflight succeeds"
  defp pause_clearance(_reason), do: "after the next control reconciliation"

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
    Aiur.DecisionStore.record_transport_batch_async(transition, List.wrap(items), reason)
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
          operator_message: %{
            request_id: request_id,
            status: :queued
          }
        }
      )
    )
  end

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

  defp control_api_call(server, request, timeout) do
    if GenServer.whereis(server) do
      GenServer.call(server, request, timeout)
    else
      {:error, :unavailable}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  defp queue_api_call(server, request) do
    GenServer.call(server, request, 5_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp validate_operator_message(body) do
    text = String.trim(body)

    cond do
      text == "" -> {:error, :empty_message}
      String.length(text) > @max_operator_message_chars -> {:error, :message_too_long}
      true -> {:ok, text}
    end
  end

  defp correlation_action_id(correlation) do
    Map.get(correlation, :action_id, Map.get(correlation, "action_id"))
  end

  @spec send_running_control_message(State.t(), String.t(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  def send_running_control_message(state, issue_identifier, build_message) do
    request_id = :erlang.unique_integer([:positive])
    send_running_control_message(state, issue_identifier, request_id, build_message)
  end

  @doc false
  @spec send_running_control_message(State.t(), String.t(), integer(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  def send_running_control_message(state, issue_identifier, request_id, build_message)
      when is_integer(request_id) and request_id > 0 and is_function(build_message, 1) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {:error, :no_running_agent}

      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          send(pid, build_message.(request_id))
          {:ok, request_id}
        else
          {:error, :agent_finished}
        end

      _ ->
        {:error, :agent_finished}
    end
  end

  @spec notify_running_queue_update(map(), term()) :: :ok
  defdelegate notify_running_queue_update(running_entry, item), to: DeliveryPolicy

  @doc false
  @spec comment_event_topic?(map()) :: boolean()
  defdelegate comment_event_topic?(event), to: DeliveryPolicy

  @spec queue_depth_for_issue(State.t(), String.t()) :: non_neg_integer()
  defdelegate queue_depth_for_issue(state, issue_identifier), to: Capabilities

  @spec pending_operator_messages_for_issue(State.t(), String.t()) :: [map()]
  defdelegate pending_operator_messages_for_issue(state, issue_identifier), to: Capabilities

  @spec issue_control_capabilities(State.t(), String.t()) :: map()
  defdelegate issue_control_capabilities(state, issue_identifier), to: Capabilities
end
