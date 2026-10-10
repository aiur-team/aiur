defmodule Aiur.Claude.CodingAgent.Methods do
  @moduledoc false
  # Notification routing for the Claude app-server stream. `Aiur.Claude.CodingAgent`
  # delegates the `Aiur.AppServer.Adapter` callbacks here because the turn loop
  # dispatches them on the backend module.

  require Logger
  alias Aiur.AgentRunner.ToolExecutor
  alias Aiur.AppServer.{Messages, OperatorDelivery, Rpc, TurnState}
  alias Aiur.AppServer.Rpc.StreamDiagnostics
  alias Aiur.Claude.{AccountMeters, CodingAgent, NotificationPolicy}

  @doc false
  @spec handle_method(map(), map(), map(), String.t(), String.t()) :: term()
  def handle_method(session, state, %{"method" => "turn/completed"} = payload, payload_string, _method) do
    Messages.emit_message(
      state.on_message,
      :turn_completed,
      %{payload: payload, raw: payload_string},
      metadata_from_message(session.port, payload)
    )

    case TurnState.turn_completion_status(payload) do
      "interrupted" -> TurnState.continue_after_turn_interrupted(state, payload)
      _ -> TurnState.continue_after_turn_completion(state)
    end
  end

  def handle_method(session, state, %{"method" => "turn/failed", "params" => params} = payload, payload_string, _method) do
    Messages.emit_message(
      state.on_message,
      :turn_failed,
      %{payload: payload, raw: payload_string, details: params},
      metadata_from_message(session.port, payload)
    )

    TurnState.fail_pending_operator_requests(state.pending_operator_requests, {:turn_failed, params})

    # CLI provenance first (#2727); provider_error text never feeds the
    # free-text fallbacks, which only see wrapper stderr and stream output.
    with :unclassified <- NotificationPolicy.provider_refusal(params, session_now(session)) do
      classify_unattributed_failure(session, params)
    end
  end

  def handle_method(
        session,
        state,
        %{"method" => "item/tool/call", "id" => id, "params" => params} = payload,
        payload_string,
        _method
      ) do
    metadata = metadata_from_message(session.port, payload)
    tool_name = Messages.tool_call_name(params)
    arguments = Messages.tool_call_arguments(params)

    result =
      state.tool_executor
      |> ToolExecutor.execute(tool_name, arguments, Messages.tool_call_id(params, id))
      |> Messages.normalize_tool_result(%{workspace: session.workspace, response_id: id})

    CodingAgent.send_frame(session.port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    Messages.emit_message(state.on_message, event, %{payload: payload, raw: payload_string}, metadata)

    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :tool_result, method: "item/tool/call"})}
  end

  def handle_method(
        session,
        state,
        %{"method" => "rate_limit/update"} = payload,
        _payload_string,
        method
      ) do
    _ = AccountMeters.handle_notification(session, payload)

    Messages.emit_message(
      state.on_message,
      :notification,
      AccountMeters.redacted_message(),
      metadata_from_message(session.port, %{"method" => "provider_account/rate_limits_changed"})
    )

    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification, method: method})}
  end

  def handle_method(session, state, %{"method" => method} = payload, payload_string, _method)
      when is_binary(method) do
    # item/created text is assistant content, even when it repeats a refusal
    # verbatim. Exhaustion is decided at turn/failed, from the CLI provenance
    # in provider_error or from provider failure diagnostics.
    Messages.emit_message(
      state.on_message,
      :notification,
      %{payload: payload, raw: payload_string},
      metadata_from_message(session.port, payload)
    )

    Logger.debug("Claude notification: #{inspect(method)}")
    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, %{kind: :notification, method: method})}
  end

  @doc false
  @spec handle_malformed(map(), String.t(), port()) :: {:continue, map()}
  def handle_malformed(state, payload_string, port) do
    Rpc.log_non_json_stream_line(payload_string, "turn stream", "Claude")

    Messages.emit_message(
      state.on_message,
      :malformed,
      %{payload: payload_string, raw: payload_string},
      metadata_from_message(port, %{raw: payload_string})
    )

    {:continue, state}
  end

  defp classify_unattributed_failure(session, params) do
    legacy_params = Map.delete(params, "provider_error")

    if NotificationPolicy.usage_limit_exhausted?(legacy_params) do
      {:paused, NotificationPolicy.usage_limit_pause(legacy_params)}
    else
      # An older wrapper reports only `"Error: claude exited with code 1"`;
      # the 429 may still be on the provider's stream (#2607).
      case NotificationPolicy.classify_stream_failure(StreamDiagnostics.recent_text(session.port)) do
        {:paused, pause} -> {:paused, pause}
        :unclassified -> {:error, {:turn_failed, params}}
      end
    end
  end

  defp session_now(session), do: Map.get(session, :clock, &DateTime.utc_now/0).()

  @doc false
  @spec metadata_from_message(port(), term()) :: map()
  def metadata_from_message(port, payload) do
    port |> port_metadata() |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}

    metadata
    |> put_if_map(:usage, find_in(payload, params, "usage", :usage))
    |> put_if_number(:cost_usd, find_in(payload, params, "cost_usd", :cost_usd))
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp find_in(top, params, str_key, atom_key) do
    Map.get(top, str_key) || Map.get(top, atom_key) ||
      Map.get(params, str_key) || Map.get(params, atom_key)
  end

  defp put_if_map(metadata, key, value) when is_map(value), do: Map.put(metadata, key, value)
  defp put_if_map(metadata, _key, _value), do: metadata

  defp put_if_number(metadata, key, value) when is_number(value),
    do: Map.put(metadata, key, value)

  defp put_if_number(metadata, _key, _value), do: metadata

  @doc false
  @spec port_metadata(port()) :: map()
  def port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{provider_pid: to_string(os_pid), claude_app_server_pid: to_string(os_pid)}
        |> maybe_put_agent_process_group(os_pid)

      _ ->
        %{}
    end
  end

  defp maybe_put_agent_process_group(metadata, group) when is_integer(group) and group > 0,
    do: Map.put(metadata, :agent_process_group_id, group)

  defp maybe_put_agent_process_group(metadata, _group), do: metadata
end
