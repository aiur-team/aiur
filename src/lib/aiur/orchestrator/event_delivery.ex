defmodule Aiur.Orchestrator.EventDelivery do
  @moduledoc """
  Default per-ticket delivery sink. Enqueue is a nonblocking cast to the
  orchestrator, which owns queue ordering and event-id deduplication.
  """
  @behaviour Aiur.Events.Delivery

  require Logger

  @impl true
  def enqueue(identifier, event, context) do
    server = Application.get_env(:aiur, :event_delivery_orchestrator, Aiur.Orchestrator)

    case GenServer.whereis(server) do
      nil ->
        {:error, :no_orchestrator}

      pid when is_pid(pid) ->
        GenServer.cast(pid, {:enqueue_event_digest_async, identifier, event, context})
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
