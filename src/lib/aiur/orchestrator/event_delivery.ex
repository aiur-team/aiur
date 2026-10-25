defmodule Aiur.Orchestrator.EventDelivery do
  @moduledoc """
  Default per-ticket delivery sink. Preserves the orchestrator enqueue timeout
  and dead-letter reporting. Dead-letter sink failures propagate to the store.
  """
  @behaviour Aiur.Events.Delivery

  require Logger

  @impl true
  def enqueue(identifier, event, context) do
    case Process.whereis(Aiur.Orchestrator) do
      nil ->
        {:error, :no_orchestrator}

      pid ->
        try do
          case GenServer.call(pid, {:enqueue_event_digest, identifier, event, context}, 1_000) do
            :ok -> :ok
            {:error, _} = err -> err
            other -> {:error, {:unexpected_return, other}}
          end
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
    end
  end

  @impl true
  def dead_letter(identifier, event_id, topic, reason, attempts) do
    Logger.warning(
      "SubscriptionStore(#{identifier}): giving up on event #{inspect(event_id)} " <>
        "on topic #{topic} after #{attempts} attempt(s): #{inspect(reason)}; " <>
        "advancing cursor past failed event"
    )

    _ =
      Aiur.Signal.alert(
        "system.subscription_store.event_dead_lettered",
        reason: "enqueue failed after #{attempts} attempt(s) for event #{inspect(event_id)} on #{topic}: #{inspect(reason)}",
        needs_attention: true,
        severity: "warning"
      )

    :ok
  end
end
