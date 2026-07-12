defmodule Aiur.Orchestrator.OperatorMessages do
  @moduledoc """
  Queues and routes operator messages and event digests to running agents. All functions execute inside the orchestrator GenServer process.
  """
  alias Aiur.{AgentQueue, AgentQueueStore, Alerts}

  alias Aiur.Orchestrator.{
    AutoSubscriptions,
    CommentWake,
    DigestCoalescer,
    State
  }

  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}
  @max_operator_message_chars 8_000

  @spec send_operator_message(String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(issue_identifier, payload),
    do: send_operator_message(Aiur.Orchestrator, issue_identifier, payload)

  @spec send_operator_message(GenServer.server(), String.t(), map()) ::
          {:ok, integer()} | {:error, term()}
  def send_operator_message(server, issue_identifier, payload),
    do: control_api_call(server, {:send_operator_message, issue_identifier, payload}, 5_000)

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

    body = %{
      summary: CommentWake.event_digest_summary(summary_source),
      events: events
    }

    running_entry = State.find_running_by_identifier(state.running, identifier)
    delivery_opts = DeliveryPolicy.event_digest_delivery_opts(running_entry, events)

    {queue_store, item} =
      AgentQueue.coordination_event(identifier, :events_digest, body, delivery_opts)
      |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

    next_state = %{state | queue_store: queue_store}

    case running_entry do
      nil ->
        :ok

      running_entry ->
        DeliveryPolicy.notify_running_queue_update(running_entry, item)
    end

    next_state
  end

  # The orchestrator may queue a terminal CI event synchronously before it
  # resumes a runner, while the durable SubscriptionStore delivers the same
  # exchange event asynchronously. Keep one queue item even if the second copy
  # arrives after the first was already delivered or consumed.
  defp reject_already_queued_events(%AgentQueueStore{} = queue_store, events) do
    known_ids =
      queue_store.items
      |> Map.values()
      |> Enum.flat_map(fn
        %{category: :coordination_event, event_type: :events_digest, body: %{events: queued}} ->
          Enum.flat_map(List.wrap(queued), fn event ->
            case event_id(event) do
              id when is_integer(id) -> [id]
              _ -> []
            end
          end)

        _ ->
          []
      end)
      |> MapSet.new()

    Enum.reject(events, fn event ->
      case event_id(event) do
        id when is_integer(id) -> MapSet.member?(known_ids, id)
        _ -> false
      end
    end)
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

  def send_operator_message_call(%State{} = state, _issue_identifier, _payload) do
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
    update_queue_store(state, &AgentQueueStore.mark_consumed(&1, item_id))
  end

  @spec restore_queue_item_pending_call(State.t(), integer()) :: {:reply, :ok, State.t()}
  def restore_queue_item_pending_call(%State{} = state, item_id) when is_integer(item_id) do
    update_queue_store(state, &AgentQueueStore.restore_pending(&1, item_id))
  end

  @spec mark_queue_item_failed_call(State.t(), integer(), term()) :: {:reply, :ok, State.t()}
  def mark_queue_item_failed_call(%State{} = state, item_id, reason) when is_integer(item_id) do
    update_queue_store(state, &AgentQueueStore.mark_failed(&1, item_id, reason))
  end

  @spec consume_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  def consume_delivered_queue_items_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.consume_delivered(&1, issue_identifier))
  end

  @spec restore_delivered_queue_items_call(State.t(), String.t()) :: {:reply, :ok, State.t()}
  def restore_delivered_queue_items_call(%State{} = state, issue_identifier)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.restore_delivered(&1, issue_identifier))
  end

  @spec fail_delivered_queue_items_call(State.t(), String.t(), term()) ::
          {:reply, :ok, State.t()}
  def fail_delivered_queue_items_call(%State{} = state, issue_identifier, reason)
      when is_binary(issue_identifier) do
    update_queue_store(state, &AgentQueueStore.fail_delivered(&1, issue_identifier, reason))
  end

  @doc false
  @spec coalesce_for_test(AgentQueueStore.t(), String.t()) ::
          {AgentQueueStore.t(), map() | nil}
  def coalesce_for_test(queue_store, issue_identifier) when is_binary(issue_identifier) do
    {queue_store, item} = AgentQueueStore.claim_next_deliverable(queue_store, issue_identifier)
    maybe_coalesce_events(queue_store, issue_identifier, item)
  end

  @spec enqueue_operator_message(State.t(), String.t(), String.t(), map()) ::
          {{:ok, integer()} | {:error, term()}, State.t()}
  def enqueue_operator_message(state, issue_identifier, body, payload) do
    delivery_policy = Map.get(payload, :delivery_policy, :checkpoint)
    fallback = Map.get(payload, :fallback)
    turn_id = Map.get(payload, :turn_id)

    case validate_operator_message(body) do
      {:ok, text} ->
        enqueue_validated_operator_message(
          state,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp enqueue_validated_operator_message(
         state,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {{:error, :no_running_agent}, state}

      running_entry ->
        enqueue_for_running_entry(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )
    end
  end

  # Chatting with a paused agent auto-resumes it — but only if a slot is
  # free. Routing through `resume_paused_issue/2` reuses the same
  # active-cap and per-state slot gates as the explicit space-key resume,
  # so we can't push active over max no matter which entry point the
  # operator uses. If no slot is free, the cap error propagates and the
  # conversation pane surfaces it.
  defp enqueue_for_running_entry(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    cond do
      State.deactivated_running_entry?(running_entry) ->
        enqueue_after_reactivate(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      State.paused_running_entry?(running_entry) ->
        enqueue_after_resume(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      true ->
        do_enqueue_running_operator_message(
          state,
          running_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )
    end
  end

  # Mirrors `enqueue_after_resume/7` for the `:deactivated → :working`
  # transition. The fresh agent task spawned by `reactivate_issue/2`
  # will pick up the queued operator message when it boots.
  defp enqueue_after_reactivate(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case Aiur.Orchestrator.reactivate_issue(state, running_entry) do
      {{:ok, :reactivated}, next_state} ->
        reactivated_entry = State.find_running_by_identifier(next_state.running, issue_identifier)

        do_enqueue_running_operator_message(
          next_state,
          reactivated_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {{:error, _reason} = error, next_state} ->
        {error, next_state}
    end
  end

  defp enqueue_after_resume(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    case Aiur.Orchestrator.resume_paused_issue(state, running_entry) do
      {{:ok, :resumed}, next_state} ->
        resumed_entry = State.find_running_by_identifier(next_state.running, issue_identifier)

        do_enqueue_running_operator_message(
          next_state,
          resumed_entry,
          issue_identifier,
          text,
          delivery_policy,
          fallback,
          turn_id
        )

      {{:error, _reason} = error, next_state} ->
        {error, next_state}
    end
  end

  defp do_enqueue_running_operator_message(
         state,
         running_entry,
         issue_identifier,
         text,
         delivery_policy,
         fallback,
         turn_id
       ) do
    capabilities = Capabilities.issue_control_capabilities(state, issue_identifier)

    case DeliveryPolicy.normalize_delivery_request(delivery_policy, fallback, capabilities) do
      {:ok, queue_opts} ->
        {queue_store, item} =
          AgentQueue.operator_message(
            issue_identifier,
            text,
            Keyword.put(queue_opts, :turn_id, turn_id)
          )
          |> then(&Aiur.AgentQueueStore.enqueue(state.queue_store, &1))

        # NOTE: previously we emitted a `chat.send` alert here for every
        # operator message. That alert was pure noise — it duplicated
        # the `[user]` line the pane already renders and added a
        # `[alert] chat.send: Message sent` row plus a log line for
        # every keystroke-submitted message. Removed.

        next_state = %{state | queue_store: queue_store}
        DeliveryPolicy.notify_running_queue_update(running_entry, item)
        {{:ok, item.id}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  @spec maybe_emit_agent_control_alert(atom(), atom(), map()) :: :ok
  def maybe_emit_agent_control_alert(
        :working,
        :paused,
        %{paused_reason: :ci_wait} = running_entry
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

  def maybe_emit_agent_control_alert(:working, :paused, running_entry)
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.paused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent paused and may need operator input before continuing.",
      needs_attention: true,
      severity: "warning"
    )
  end

  def maybe_emit_agent_control_alert(:paused, :working, running_entry)
      when is_map(running_entry) do
    Alerts.emit_system("ticket.#{Map.get(running_entry, :identifier)}.agent.unpaused",
      issue: Map.get(running_entry, :identifier),
      workspace: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      reason: "Agent resumed; no operator action is needed.",
      needs_attention: false,
      severity: "info"
    )
  end

  def maybe_emit_agent_control_alert(_previous_status, _status, _running_entry), do: :ok

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

  defp update_queue_store(%State{} = state, update) when is_function(update, 1) do
    {queue_store, _items} = update.(state.queue_store)
    {:reply, :ok, %{state | queue_store: queue_store}}
  end

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

  @spec send_running_control_message(State.t(), String.t(), (integer() -> term())) ::
          {:ok, integer()} | {:error, atom()}
  def send_running_control_message(state, issue_identifier, build_message) do
    case State.find_running_by_identifier(state.running, issue_identifier) do
      nil ->
        {:error, :no_running_agent}

      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          request_id = :erlang.unique_integer([:positive])
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
