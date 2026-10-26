defmodule Aiur.AgentRunner.QueueTurn do
  @moduledoc false
  require Logger
  alias Aiur.AgentPubSub
  alias Aiur.AgentRunner.EventsDigest
  alias Aiur.AgentRunner.MessageHandler
  alias Aiur.AgentRunner.QueueDrain
  alias Aiur.AgentRunner.SessionLifecycle
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AgentRunner.TurnCallbacks
  alias Aiur.AgentRunner.TurnLoop
  alias Aiur.AgentRunner.TurnStreams
  alias Aiur.AgentTools.Dispatch
  alias Aiur.CodingAgent
  alias Aiur.Workspace
  import Aiur.AgentRunner.DeliveryCorrelation

  @doc false
  @spec queue_item_text(map()) :: String.t()
  def queue_item_text(%{category: :operator_message, body: %{text: text}}), do: text

  def queue_item_text(
        %{
          category: :coordination_event,
          event_type: :events_digest,
          body: %{events: events, urgent: true}
        } = item
      )
      when is_list(events) do
    events
    |> EventsDigest.render(Map.get(item, :target_issue_identifier))
    |> String.replace("<aiur:events>", "<aiur:events urgent=\"true\">", global: false)
  end

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

  @doc false
  @spec run_queue_item_turn(term(), term(), term(), term(), term(), term(), term()) :: term()
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def run_queue_item_turn(
        app_session,
        issue,
        item,
        _message_handler,
        orchestrator,
        codex_update_recipient,
        opts
      ) do
    case prepare_operator_delivery(item, issue) do
      :ok ->
        run_recorded_queue_item_turn(
          app_session,
          issue,
          item,
          orchestrator,
          codex_update_recipient,
          opts
        )

      {:error, outcome} ->
        Logger.warning("Settling uncorrelated queue delivery for #{Aiur.AgentRunner.issue_context(issue)} request_id=#{item.id} outcome=#{inspect(outcome)}")

        TurnLoop.best_effort_queue_bookkeeping(settle_operator_delivery_failure(orchestrator, item, outcome), :settle, issue)
        :ok
    end
  end

  defp maybe_broadcast_turn_completed(turn_id, issue) when is_binary(turn_id),
    do: AgentPubSub.broadcast_turn_event(issue.identifier, :turn_completed, %{turn_id: turn_id})

  defp maybe_broadcast_turn_completed(_turn_id, _issue), do: :ok

  # #2697: a queued operator message starts a turn too; verify the agent's
  # GitHub support first, exactly as `TurnLoop.run_turns/10` does. A refused
  # turn never started, so the delivered item is restored to pending through
  # the confirmed restore boundary instead of being marked failed.
  defp run_recorded_queue_item_turn(
         app_session,
         issue,
         item,
         orchestrator,
         codex_update_recipient,
         opts
       ) do
    workspace = SessionLifecycle.session_workspace(app_session)
    worker_host = SessionLifecycle.session_worker_host(app_session)

    case Workspace.ensure_agent_support_before_turn(workspace, issue, worker_host) do
      :ok ->
        run_supported_queue_item_turn(app_session, issue, item, orchestrator, codex_update_recipient, opts)

      {:error, _reason} = error ->
        TurnLoop.confirm_restore_for_replacement(orchestrator, issue, opts, error)
    end
  end

  defp run_supported_queue_item_turn(
         app_session,
         issue,
         item,
         orchestrator,
         codex_update_recipient,
         opts
       ) do
    text = queue_item_text(item)
    turn_id = queue_item_turn_id(item)
    workspace = SessionLifecycle.session_workspace(app_session)
    worker_host = SessionLifecycle.session_worker_host(app_session)

    backend = SessionLifecycle.session_backend!(app_session)

    callbacks =
      TurnCallbacks.build(
        app_session,
        issue,
        opts
        |> Keyword.put(:workspace, workspace)
        |> Keyword.put(:worker_host, worker_host)
        |> Keyword.put(:recipient, codex_update_recipient)
        |> Keyword.put(:orchestrator, orchestrator)
        |> Keyword.put(:turn_id, turn_id)
      )

    message_handler = callbacks.on_message

    MessageHandler.send_control_state(codex_update_recipient, issue, :working)
    aiur_turn_id = TurnStreams.open(issue)

    :ok = Dispatch.reset_turn_quotas()

    result =
      coding_agent_run_turn(opts).(
        app_session,
        text,
        issue,
        on_message: message_handler,
        on_safe_checkpoint: callbacks.on_safe_checkpoint,
        on_operator_message: callbacks.on_operator_message,
        on_operator_response: callbacks.on_operator_response,
        on_provider_delivery: provider_delivery_callback(orchestrator, item, issue),
        tool_executor: ToolExecutor.build(issue, workspace, worker_host, app_session, attempt_id: Keyword.get(opts, :telemetry_attempt_id), rework_head_sha: Keyword.get(opts, :rework_head_sha))
      )

    TurnStreams.close(issue, aiur_turn_id, TurnLoop.turn_done_reason(result))

    case result do
      {:ok, _turn_session} ->
        complete_queue_item_turn(orchestrator, issue, item, backend, callbacks.live_opts, turn_id)

        QueueDrain.drain_operator_messages(
          app_session,
          issue,
          message_handler,
          orchestrator,
          codex_update_recipient,
          opts
        )

      {:paused, pause_payload} ->
        context = %{issue: issue, workspace: workspace, worker_host: worker_host, orchestrator: orchestrator, codex_update_recipient: codex_update_recipient, opts: opts}

        TurnLoop.settle_paused_turn(context, app_session, pause_payload, message_handler, fn ->
          complete_queue_item_turn(orchestrator, issue, item, backend, callbacks.live_opts, turn_id)
        end)

      {:error, {:turn_start_failed, reason}} when reason in [:response_timeout, :turn_timeout] ->
        # Reporting a successful requeue without a durable restore would strand the claimed message.
        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)

        Logger.info(
          "Queued item delivery lost completion race for #{Aiur.AgentRunner.issue_context(issue)} " <>
            "request_id=#{item.id} reason=#{inspect(reason)} decision=requeue_after_parent_turn_completed"
        )

        :ok

      {:error, {:turn_start_failed, {:response_error, %{"code" => -32_003}}}} ->
        # Reporting a successful requeue without a durable restore would strand the claimed message.
        :ok = Aiur.Orchestrator.restore_delivered_queue_items(orchestrator, issue.identifier)

        Logger.info(
          "Queued item delivery hit provider active turn for #{Aiur.AgentRunner.issue_context(issue)} " <>
            "request_id=#{item.id} decision=restore_pending reason=active_turn"
        )

        :ok

      {:error, reason} ->
        settle_failed_queue_item_turn(orchestrator, issue, turn_id, backend, reason, opts)
    end
  end

  defp complete_queue_item_turn(orchestrator, issue, item, backend, opts, turn_id) do
    maybe_observe_accepted_operator_delivery(issue, item, backend, opts)
    TurnLoop.best_effort_queue_bookkeeping(Aiur.Orchestrator.consume_delivered_queue_items(orchestrator, issue.identifier), :consume, issue)
    maybe_broadcast_turn_completed(turn_id, issue)
  end

  # A provider-classified recoverable session failure routes through the one confirmed restore-and-replace
  # boundary: the durable item is restored to pending and the recoverable error
  # is returned so the runner clean-exits for a fresh transport. Issue #1238
  # showed the old `:ok = restore_delivered_queue_items(...)` hard match raised a
  # MatchError on a transient `{:error, :unavailable}`, converting recovery into
  # an abnormal exit that consumed a failure retry. Genuine provider
  # failures keep the fail-and-broadcast settlement.
  defp settle_failed_queue_item_turn(orchestrator, issue, turn_id, backend, reason, opts) do
    if CodingAgent.recoverable_session_error?(backend, reason) do
      TurnLoop.confirm_restore_for_replacement(orchestrator, issue, opts, {:error, reason})
    else
      fail_queue_item_turn(orchestrator, issue, turn_id, reason)
      {:error, reason}
    end
  end

  defp fail_queue_item_turn(orchestrator, issue, turn_id, reason) do
    TurnLoop.best_effort_queue_bookkeeping(Aiur.Orchestrator.fail_delivered_queue_items(orchestrator, issue.identifier, reason), :fail, issue)

    if is_binary(turn_id) do
      AgentPubSub.broadcast_turn_event(issue.identifier, :turn_failed, %{
        turn_id: turn_id,
        reason: reason
      })
    end

    :ok
  end

  defp maybe_observe_accepted_operator_delivery(
         issue,
         %{category: :operator_message} = item,
         backend,
         opts
       ) do
    opts = Keyword.put(opts, :occurred_at, operator_delivery_occurred_at(item))
    MessageHandler.observe_operator_delivery(issue, item, backend, opts)
  end

  defp maybe_observe_accepted_operator_delivery(_issue, _item, _backend, _opts), do: :ok

  defp operator_delivery_occurred_at(item) do
    Enum.find([Map.get(item, :delivered_at), Map.get(item, :inserted_at)], &is_struct(&1, DateTime))
  end

  defp queue_item_turn_id(%{turn_id: turn_id}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(%{body: %{turn_id: turn_id}}) when is_binary(turn_id), do: turn_id
  defp queue_item_turn_id(_item), do: nil

  defp provider_delivery_callback(orchestrator, item, issue) do
    fn provider_metadata ->
      :ok = record_provider_delivery(item, issue)
      acknowledge_provider_delivery(orchestrator, item, provider_metadata)
    end
  end

  defp coding_agent_run_turn(opts), do: Keyword.get(opts, :run_turn, &CodingAgent.run_turn/4)
end
