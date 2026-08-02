defmodule Aiur.AgentList.EventIntake do
  @moduledoc """
  Pure fold for AgentList's debug-only event ticker.
  """

  # Cap on the in-memory debug-event ticker buffer. The renderer trims
  # further based on available pane height, but this stops unbounded
  # growth if the Executor leaves --debug on for hours.
  @debug_event_cap 200

  @spec fold(map(), map()) :: map()
  def fold(state, entry) do
    if state.debug_mode? do
      new_events = [entry | state.debug_events] |> Enum.take(@debug_event_cap)
      %{state | debug_events: new_events}
    else
      state
    end
  end
end
