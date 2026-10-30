defmodule Aiur.Listener.ModeCopy do
  @moduledoc "Listener wording from Khala 7d0a3d44 (listener v1)."

  @spec label(term()) :: String.t()
  def label(:steer), do: "Steer · interrupts"
  def label(:sync), do: "Sync · next turn"
  def label(:async), do: "Async · pings only"
  def label(:mute), do: "Mute · silent"
  def label(_), do: "Unavailable"
end
