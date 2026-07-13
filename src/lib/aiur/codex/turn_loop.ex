defmodule Aiur.Codex.TurnLoop do
  @moduledoc """
  Codex-specific app-server method routing for turn events and notifications.
  """

  require Logger

  alias Aiur.AppServer.{Messages, OperatorDelivery, Rpc, TurnState}
  alias Aiur.Codex.{Approvals, NotificationPolicy, TurnEvents}

  @spec handle_method(map(), map(), map(), String.t(), String.t()) :: term()
  def handle_method(session, state, %{"method" => "turn/completed"} = payload, payload_string, _method) do
    emit_turn_event(state.on_message, :turn_completed, payload, payload_string, session.port, payload)

    case TurnState.turn_completion_status(payload) do
      "interrupted" -> TurnState.continue_after_turn_interrupted(state, payload)
      _ -> TurnState.continue_after_turn_completion(state)
    end
  end

  def handle_method(session, state, %{"method" => "turn/failed", "params" => params} = payload, payload_string, _method) do
    emit_turn_event(state.on_message, :turn_failed, payload, payload_string, session.port, params)
    TurnState.fail_pending_operator_requests(state.pending_operator_requests, {:turn_failed, params})
    {:error, {:turn_failed, params}}
  end

  def handle_method(session, state, %{"method" => "turn/cancelled", "params" => params} = payload, payload_string, _method) do
    emit_turn_event(state.on_message, :turn_cancelled, payload, payload_string, session.port, params)
    TurnState.fail_pending_operator_requests(state.pending_operator_requests, {:turn_cancelled, params})

    if is_integer(state.pause_request_id) do
      {:paused,
       %{
         request_id: state.pause_request_id,
         turn_id: state.current_turn_id,
         details: params
       }}
    else
      {:error, {:turn_cancelled, params}}
    end
  end

  def handle_method(session, state, %{"method" => method} = payload, payload_string, _method)
      when is_binary(method) do
    handle_turn_method(session, state, payload, payload_string, method)
  end

  @spec handle_malformed(map(), String.t(), port()) :: {:continue, map()}
  def handle_malformed(state, payload_string, port) do
    Rpc.log_non_json_stream_line(payload_string, "turn stream", "Codex")

    if NotificationPolicy.protocol_message_candidate?(payload_string) do
      Messages.emit_message(
        state.on_message,
        :malformed,
        %{
          payload: payload_string,
          raw: payload_string
        },
        TurnEvents.metadata_from_message(port, %{raw: payload_string})
      )
    end

    {:continue, state}
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    Messages.emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      TurnEvents.metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(%{port: port} = session, state, payload, payload_string, method) do
    on_message = state.on_message

    metadata =
      port
      |> TurnEvents.metadata_from_message(payload)
      |> Map.put(:workspace, Map.get(session, :workspace))

    case Approvals.maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           state.tool_executor,
           state.auto_approve_requests,
           pause_latched?(session, state)
         ) do
      :input_required ->
        Messages.emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        checkpoint = NotificationPolicy.checkpoint_for_method(method)
        {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, checkpoint)}

      :approval_required ->
        Messages.emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        handle_unhandled_method(session, state, method, payload, payload_string, on_message, metadata)
    end
  end

  defp pause_latched?(session, state) do
    is_integer(state.pause_request_id) or Aiur.PauseContainment.paused?(Map.get(session, :containment))
  end

  defp handle_unhandled_method(session, state, method, payload, payload_string, on_message, metadata) do
    if NotificationPolicy.needs_input?(method, payload) do
      Messages.emit_message(on_message, :turn_input_required, %{payload: payload, raw: payload_string}, metadata)
      {:error, {:turn_input_required, payload}}
    else
      Messages.emit_message(on_message, :notification, %{payload: payload, raw: payload_string}, metadata)
      handle_notification_outcome(session, state, method, payload)
    end
  end

  # Surface error-class notifications at info level with the full payload
  # so the operator log shows the actual codex failure (API rate limit,
  # auth error, bwrap sandbox refusal, etc.) instead of an opaque
  # `Codex notification: "error"` line that requires combing through
  # 1000s of lines of debug-tier `Ignoring message while waiting for
  # response` detail to reconstruct.
  #
  # When codex reports it will not retry (e.g. usageLimitExceeded with
  # willRetry:false) end the turn as a hard failure instead of :continue.
  # :continue lets the turn finish "normally", after which the
  # orchestrator respawns it every ~1s, uncapped; a hard failure routes
  # through the orchestrator's max_retry_attempts cap and backoff.
  defp handle_notification_outcome(session, state, method, payload) do
    cond do
      NotificationPolicy.codex_quota_exhausted?(method, payload) ->
        Logger.warning("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; codex account usage quota exhausted — pausing agent instead of burning retries")

        {:paused, NotificationPolicy.usage_limit_pause(payload, method)}

      NotificationPolicy.codex_error_method?(method) and NotificationPolicy.unretryable_codex_error?(payload) ->
        Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; willRetry=false, ending turn as unretryable")
        {:error, {:turn_unretryable, NotificationPolicy.codex_error_reason(payload, method)}}

      NotificationPolicy.turn_started_method?(method) ->
        checkpoint = NotificationPolicy.checkpoint_for_method(method)

        next_state =
          session
          |> OperatorDelivery.maybe_process_safe_checkpoint(%{state | turn_started?: true}, checkpoint)

        {:continue, next_state}

      state.turn_started? and NotificationPolicy.thread_idle_status?(method, payload) ->
        Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; treating idle status as turn completion")
        TurnState.continue_after_turn_completion(state)

      NotificationPolicy.codex_error_method?(method) ->
        Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}")
        checkpoint = NotificationPolicy.checkpoint_for_method(method)
        {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, checkpoint)}

      true ->
        Logger.debug("Codex notification: #{inspect(method)}")
        checkpoint = NotificationPolicy.checkpoint_for_method(method)
        {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, checkpoint)}
    end
  end
end
