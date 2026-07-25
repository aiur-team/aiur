defmodule Aiur.Codex.TurnLoop do
  @moduledoc """
  Codex-specific app-server method routing for turn events and notifications.
  """

  alias Aiur.AppServer.{Messages, OperatorDelivery, Rpc, TurnState}
  alias Aiur.Codex.{Approvals, NotificationPolicy, Notifications, TurnEvents}

  @spec handle_method(map(), map(), map(), String.t(), String.t()) :: term()
  def handle_method(
        session,
        state,
        %{"method" => "turn/completed"} = payload,
        payload_string,
        _method
      ) do
    emit_turn_event(
      state.on_message,
      :turn_completed,
      payload,
      payload_string,
      session.port,
      payload
    )

    case TurnState.turn_completion_status(payload) do
      "interrupted" -> TurnState.continue_after_turn_interrupted(state, payload)
      _ -> TurnState.continue_after_turn_completion(state, payload)
    end
  end

  def handle_method(
        session,
        state,
        %{"method" => "turn/failed", "params" => params} = payload,
        payload_string,
        _method
      ) do
    emit_turn_event(state.on_message, :turn_failed, payload, payload_string, session.port, params)

    TurnState.fail_pending_operator_requests(
      state.pending_operator_requests,
      {:turn_failed, params}
    )

    {:error, {:turn_failed, params}}
  end

  def handle_method(
        session,
        state,
        %{"method" => "turn/cancelled", "params" => params} = payload,
        payload_string,
        _method
      ) do
    emit_turn_event(
      state.on_message,
      :turn_cancelled,
      payload,
      payload_string,
      session.port,
      params
    )

    TurnState.fail_pending_operator_requests(
      state.pending_operator_requests,
      {:turn_cancelled, params}
    )

    _ = TurnState.retire_provider_work(state)

    case state.pause_request_id do
      nil ->
        {:error, {:turn_cancelled, params}}

      request_id ->
        {:paused, TurnState.pause_result_payload(request_id, state.current_turn_id, params)}
    end
  end

  def handle_method(
        session,
        state,
        %{"method" => <<"account/", _rest::binary>> = method} = payload,
        _payload_string,
        _method
      ) do
    Notifications.handle_account(session, state, method, payload)
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

    metadata = TurnEvents.metadata_from_message(port, payload)

    execution_context = %{
      workspace: Map.get(session, :workspace),
      response_id: Map.get(payload, "id"),
      tool_call_scope: tool_call_scope(state, session),
      tool_call_thread_id: Map.get(session, :thread_id)
    }

    case Approvals.maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           state.tool_executor,
           state.auto_approve_requests,
           execution_context,
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

      {:error, reason} ->
        {:error, reason}

      :unhandled ->
        Notifications.handle_unhandled(
          session,
          state,
          method,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp pause_latched?(session, state) do
    not is_nil(state.pause_request_id) or Aiur.PauseContainment.paused?(Map.get(session, :containment))
  end

  defp tool_call_scope(%{issue_identifier: issue_identifier}, _session)
       when is_binary(issue_identifier),
       do: issue_identifier

  defp tool_call_scope(_state, _session), do: nil
end
