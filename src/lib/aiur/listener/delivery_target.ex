defmodule Aiur.Listener.DeliveryTarget do
  @moduledoc "Composition seam for serialized listener-mode control."

  @callback get_mode(Aiur.Listener.target()) :: Aiur.Listener.result()
  @callback set_mode(Aiur.Listener.target(), Aiur.Listener.ModeStore.mode(), keyword()) :: Aiur.Listener.result()
end
