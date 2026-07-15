defmodule Aiur.Codex.Notifications do
  @moduledoc false

  require Logger

  alias Aiur.AppServer.{Messages, OperatorDelivery, TurnState}
  alias Aiur.Codex.{AccountGeneration, NotificationPolicy, TurnEvents}

  @spec handle_account(map(), map(), String.t(), map()) :: {:continue, map()} | term()
  def handle_account(session, state, method, payload) do
    case AccountGeneration.handle_notification(session, method, payload) do
      {:redacted, details} ->
        Messages.emit_message(
          state.on_message,
          :notification,
          details,
          TurnEvents.metadata_from_message(session.port, details.payload)
        )

        continue_after_account_notification(session, state, details.payload["method"])

      :ignore ->
        {:continue, state}
    end
  end

  @spec handle_unhandled(map(), map(), String.t(), map(), String.t(), (map() -> term()), map()) :: term()
  def handle_unhandled(session, state, method, payload, payload_string, on_message, metadata) do
    if NotificationPolicy.needs_input?(method, payload) do
      Messages.emit_message(on_message, :turn_input_required, %{payload: payload, raw: payload_string}, metadata)
      {:error, {:turn_input_required, payload}}
    else
      handle_notification(session, state, method, payload, payload_string, on_message, metadata)
    end
  end

  defp handle_notification(session, state, method, payload, payload_string, on_message, metadata) do
    case AccountGeneration.handle_notification(session, method, payload) do
      {:redacted, details} ->
        Messages.emit_message(
          on_message,
          :notification,
          details,
          TurnEvents.metadata_from_message(session.port, details.payload)
        )

        continue_after_account_notification(session, state, details.payload["method"])

      :ignore ->
        Messages.emit_message(on_message, :notification, %{payload: payload, raw: payload_string}, metadata)
        continue_after_notification(session, state, method, payload)
    end
  end

  defp continue_after_account_notification(session, state, safe_method) do
    checkpoint = NotificationPolicy.checkpoint_for_method(safe_method)
    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, checkpoint)}
  end

  defp continue_after_notification(session, state, method, payload) do
    cond do
      NotificationPolicy.codex_quota_exhausted?(method, payload) ->
        Logger.warning("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; codex account usage quota exhausted — pausing agent instead of burning retries")
        _ = TurnState.retire_provider_work(state)
        {:paused, NotificationPolicy.usage_limit_pause(payload, method)}

      NotificationPolicy.codex_error_method?(method) and NotificationPolicy.unretryable_codex_error?(payload) ->
        Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; willRetry=false, ending turn as unretryable")
        {:error, {:turn_unretryable, NotificationPolicy.codex_error_reason(payload, method)}}

      NotificationPolicy.turn_started_method?(method) ->
        checkpoint = NotificationPolicy.checkpoint_for_method(method)

        tracked_state =
          state
          |> Map.put(:turn_started?, true)
          |> TurnState.register_provider_turn(get_in(payload, ["params", "turn"]) || %{})

        next_state = OperatorDelivery.maybe_process_safe_checkpoint(session, tracked_state, checkpoint)
        {:continue, next_state}

      idle_after_turn_started?(state, method, payload) ->
        handle_idle_notification(state, method, payload)

      NotificationPolicy.codex_error_method?(method) ->
        Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}")
        continue_after_checkpoint(session, state, method)

      true ->
        Logger.debug("Codex notification: #{inspect(method)}")
        continue_after_checkpoint(session, state, method)
    end
  end

  defp continue_after_checkpoint(session, state, method) do
    checkpoint = NotificationPolicy.checkpoint_for_method(method)
    {:continue, OperatorDelivery.maybe_process_safe_checkpoint(session, state, checkpoint)}
  end

  defp idle_after_turn_started?(state, method, payload) do
    state.turn_started? and NotificationPolicy.thread_idle_status?(method, payload)
  end

  defp handle_idle_notification(%{interrupt_action: action} = state, method, payload)
       when action in [:pause, :operator_message] do
    Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; reconciling interrupt handshake")
    TurnState.observe_interrupt_idle(state, payload)
  end

  defp handle_idle_notification(state, method, payload) do
    Logger.info("Codex notification: #{inspect(method)} payload=#{inspect(payload)}; treating idle status as turn completion")
    TurnState.complete_all_provider_turns(state)
  end
end
