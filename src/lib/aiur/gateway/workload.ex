defmodule Aiur.Gateway.Workload do
  @moduledoc """
  Workload of one gateway: `idle|active|unknown`.

  v1 has only the running-agent count. `saturated` and `paused` need capacity and pause state that no
  read command exposes yet (MPG-602); until then they are never derived, and anything not `online`
  is `unknown` -- an unreachable gateway is never `idle`.
  """

  @spec derive(String.t(), non_neg_integer() | nil) :: String.t()
  def derive("online", running) when is_integer(running) and running > 0, do: "active"
  def derive("online", running) when is_integer(running), do: "idle"
  def derive(_connectivity, _running), do: "unknown"
end
