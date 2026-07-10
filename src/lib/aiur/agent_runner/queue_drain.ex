defmodule Aiur.AgentRunner.QueueDrain do
  @moduledoc """
  Operator queue drain, paused-wait loop, and queue-item turn execution.

  Owns the receive loops that block the runner Task process while paused,
  the claim/dispatch cycle for each queued operator message or event digest,
  and the exactly-once consume/restore/fail settlement per FI-ORC-072 and
  FI-ORC-073.

  All functions here execute **in the runner Task process** — never wrap them
  in a new process, Task.async, or GenServer; doing so silently loses the
  `:pause_agent` / `:resume_agent` / `:agent_queue_updated` control messages
  that this loop receives.
  """

  require Logger

  alias Aiur.{AgentPubSub, Issue, OperatorWaitLog}
  alias Aiur.AgentRunner.{CheckpointDelivery, EventsDigest, MessageHandler, SessionLifecycle}
  alias Aiur.AgentRunner.{ToolExecutor, TurnAlerts, TurnLoop, TurnStreams}
  alias Aiur.Codex.DynamicTool
  alias Aiur.CodingAgent

  @doc false
  @spec drain_operator_messages(map(), Issue.t(), fun(), GenServer.server(), pid() | nil) :: :ok | {:error, term()}
  def drain_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    receive do
      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    after
      0 -> drain_queued_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  # Paused state. Wait for an explicit wake signal — a new
  # `:agent_queue_updated` broadcast from the orchestrator, or a
  # `:resume_agent` control message — before touching the operator
  # queue. Eagerly claiming on entry was a foot-gun: when the operator
  # paused mid-turn, `restore_delivered_queue_items/2` put the in-flight
  # item back in the queue, and the very next entry to this function
  # would re-claim and re-resume in a tight loop that no amount of
  # repeat pause-key presses could escape.
  @doc false
  @spec wait_for_operator_message(map(), Issue.t(), fun(), GenServer.server(), pid() | nil) :: :ok | {:error, term()}
  def wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    receive do
      {:agent_queue_updated, issue_identifier, _item_id} when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          true
        )

      {:agent_queue_updated, issue_identifier, _item_id, deliver_now?}
      when issue_identifier == issue.identifier ->
        try_claim_after_queue_update(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          deliver_now?
        )

      {:pause_agent, request_id} when is_integer(request_id) ->
        Logger.info("Agent already paused for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:resume_agent, request_id} when is_integer(request_id) ->
        Logger.info("Resuming paused agent for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{request_id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :working)
        # An explicit resume drains the agent queue so restored items
        # land in the same turn instead of being deferred until the next
        # checkpoint of an initial-prompt turn.
        claim_and_run_or_continue(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  @doc false
  @spec claim_after_queue_update(GenServer.server(), String.t(), boolean()) ::
          {:ok, map()} | :empty | :ignored
  def claim_after_queue_update(orchestrator, issue_identifier, true) do
    claim_next_wake_queue_item(orchestrator, issue_identifier)
  end

  def claim_after_queue_update(_orchestrator, _issue_identifier, false), do: :ignored

  @doc false
  @spec record_operator_delivery(map(), map()) :: :ok
  def record_operator_delivery(%{category: :operator_message, id: request_id}, %{identifier: identifier})
      when is_integer(request_id) and is_binary(identifier) do
    OperatorWaitLog.record_delivered(request_id, identifier)
  end

  def record_operator_delivery(_item, _issue), do: :ok

  @doc false
  @spec claim_next_operator_item(GenServer.server(), String.t()) :: {:ok, map()} | :empty
  def claim_next_operator_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_operator_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  @doc false
  @spec queue_item_text(map()) :: String.t()
  def queue_item_text(%{category: :operator_message, body: %{text: text}}), do: text

  def queue_item_text(
        %{
          category: :coordination_event,
          event_type: :events_digest,
          body: %{events: events}
        } = item
      )
      when is_list(events) do
    EventsDigest.render(events, Map.get(item, :target_issue_identifier))
  end

  def queue_item_text(%{category: :coordination_event, event_type: event_type, body: body}) do
    summary = Map.get(body, :summary) || Map.get(body, "summary") || inspect(body)

    """
    Coordination event: #{event_type}

    #{summary}
    """
    |> String.trim()
  end

  def queue_item_text(item), do: inspect(item)

  defp try_claim_after_queue_update(app_session, issue, message_handler, orchestrator, codex_update_recipient, deliver_now?) do
    case claim_after_queue_update(orchestrator, issue.identifier, deliver_now?) do
      {:ok, item} ->
        Logger.info("Resuming paused agent for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id}")
        MessageHandler.send_control_state(codex_update_recipient, issue, :working)
        run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      :ignored ->
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)
    end
  end

  defp claim_and_run_or_continue(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    case claim_next_wake_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        :ok
    end
  end

  defp drain_queued_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient) do
    case claim_next_queue_item(orchestrator, issue.identifier) do
      {:ok, item} ->
        Logger.info("Delivering queued item to #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} category=#{item.category}")
        run_queue_item_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)

      :empty ->
        :ok
    end
  end

  defp claim_next_queue_item(orchestrator, issue_identifier) when is_binary(issue_identifier) do
    case Aiur.Orchestrator.claim_next_queue_item(orchestrator, issue_identifier) do
      {:ok, item} -> {:ok, item}
      :empty -> :empty
      {:error, _reason} -> :empty
    end
  end

  defp claim_next_wake_queue_item(orchestrator, issue_identifier) do
    claim_next_queue_item(orchestrator, issue_identifier)
  end

  defp run_operator_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient) do
    run_queue_item_turn(app_session, issue, item, message_handler, orchestrator, codex_update_recipient)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  defp run_queue_item_turn(app_session, issue, item, _message_handler, orchestrator, codex_update_recipient) do
    record_operator_delivery(item, issue)
    text = queue_item_text(item)
    turn_id = queue_item_turn_id(item)
    workspace = SessionLifecycle.session_workspace(app_session)
    worker_host = SessionLifecycle.session_worker_host(app_session)

    backend = SessionLifecycle.session_backend(app_session)

    message_handler =
      MessageHandler.build(codex_update_recipient, issue, workspace, worker_host, backend, turn_id)

    safe_checkpoint_handler = CheckpointDelivery.safe_checkpoint_handler(issue, orchestrator)

    MessageHandler.send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = TurnStreams.open(issue)

    :ok = DynamicTool.reset_turn_quotas()

    result =
      CodingAgent.run_turn(
        app_session,
        text,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: safe_checkpoint_handler,
        on_operator_message: CheckpointDelivery.operator_immediate_handler(issue, orchestrator),
        tool_executor:
          ToolExecutor.build(
            issue,
            SessionLifecycle.session_workspace(app_session),
            SessionLifecycle.session_worker_host(app_session)
          )
      )

    TurnStreams.close(issue, aiur_turn_id, TurnLoop.turn_done_reason(result))

    case result do
      {:ok, _turn_session} ->
        :ok = Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier)

        if is_binary(turn_id) do
          AgentPubSub.broadcast_turn_event(issue.identifier, :turn_completed, %{turn_id: turn_id})
        end

        drain_operator_messages(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:paused, pause_payload} ->
        TurnAlerts.maybe_emit_usage_limit_alert(
          issue,
          SessionLifecycle.session_workspace(app_session),
          SessionLifecycle.session_worker_host(app_session),
          pause_payload
        )

        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)

        Aiur.AgentRunner.write_pause_log(
          SessionLifecycle.session_workspace(app_session),
          SessionLifecycle.session_worker_host(app_session)
        )

        MessageHandler.send_control_state(codex_update_recipient, issue, :paused)
        wait_for_operator_message(app_session, issue, message_handler, orchestrator, codex_update_recipient)

      {:error, {:turn_start_failed, reason}} when reason in [:response_timeout, :turn_timeout] ->
        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)

        Logger.info(
          "Queued item delivery lost completion race for #{Aiur.AgentRunner.issue_context(issue)} " <>
            "request_id=#{item.id} reason=#{inspect(reason)} decision=requeue_after_parent_turn_completed"
        )

        :ok

      {:error, reason} = error ->
        :ok = Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason)

        if is_binary(turn_id) do
          AgentPubSub.broadcast_turn_event(issue.identifier, :turn_failed, %{turn_id: turn_id, reason: reason})
        end

        error
    end
  end

  defp queue_item_turn_id(%{turn_id: turn_id}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(%{body: %{turn_id: turn_id}}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(_item), do: nil
end
