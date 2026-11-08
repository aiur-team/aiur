defmodule Aiur.Orchestrator.PauseGuard do
  @moduledoc """
  Whether dispatch is stopped: the local switch (`globally_paused`, persisted) OR the fleet pause
  register (`fleet_paused`, derived from shared intent and never persisted locally).
  """

  defguard effective_paused?(state)
           when is_map(state) and
                  (:erlang.map_get(:globally_paused, state) == true or :erlang.map_get(:fleet_paused, state) == true)

  @spec paused?(map()) :: boolean()
  def paused?(state), do: Map.get(state, :globally_paused) == true or Map.get(state, :fleet_paused) == true
end
