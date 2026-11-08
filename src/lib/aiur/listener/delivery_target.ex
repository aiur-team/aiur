defmodule Aiur.Listener.DeliveryTarget do
  @moduledoc "Composition seam for serialized listener control and snapshot reads."

  @doc "Advertise only once Executor refs can be sent to the hook queue and observed by receipt."
  @callback executor_delivery_installed?() :: boolean()
  @optional_callbacks executor_delivery_installed?: 0

  @doc "Enqueue text with the options normalized by Aiur.Listener.send/3."
  @callback enqueue(Aiur.Listener.target(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  @callback get_mode(Aiur.Listener.target()) :: Aiur.Listener.result()
  @callback set_mode(Aiur.Listener.target(), Aiur.Listener.ModeStore.mode(), keyword()) :: Aiur.Listener.result()
  @callback read_snapshot(integer(), timeout()) :: {:ok, term()} | {:error, term()}
end
