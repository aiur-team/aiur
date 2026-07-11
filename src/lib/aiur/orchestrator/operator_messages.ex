defmodule Aiur.Orchestrator.OperatorMessages do
  @moduledoc """
  Queues and routes operator messages and event digests to running agents. All functions execute inside the orchestrator GenServer process.
  """
  alias Aiur.{AgentQueue, Alerts}
  alias Aiur.Orchestrator.{CommentWake, State}
  alias Aiur.Orchestrator.OperatorMessages.{Capabilities, DeliveryPolicy}
  @max_operator_message_chars 8_000

  @spec enqueue_event_digest_item(State.t(), String.t(), list(), map()) :: State.t()
  def enqueue_event_digest_item(%State{} = state, identifier, events, summary_source)
      when is_binary(identifier) and is_list(events) do
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
