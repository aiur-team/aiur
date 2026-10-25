defmodule Aiur.Events.Delivery do
  @moduledoc """
  Sink for per-ticket subscription delivery.

  The context carries the current bindings without a synchronous call back to
  the store. Enqueue exceptions become permanent delivery failures; dead-letter
  exceptions propagate, just as failures of the default alert sink do.
  """

  # aiur:event-bus-boundary-member
  @type result :: :ok | {:error, term()}
  @type context :: %{subscribed_to: [Aiur.Events.SubscriptionStore.subscription()]}
  @callback enqueue(identifier :: String.t(), event :: map(), context()) :: result()
  @callback dead_letter(identifier :: String.t(), event_id :: integer(), topic :: String.t(), reason :: term(), attempts :: pos_integer()) :: :ok
end
