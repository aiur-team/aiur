defmodule SymphonyElixir.AgentList.Renderer do
  @moduledoc """
  Pure rendering function for the agent-list pane.

  Takes a snapshot (running set summaries), terminal geometry, and selection
  state. Returns iodata. No GenServer, no side effects, trivially testable.

  Scaffold: contract is documented; the rendering body lands together with
  the agent-list pane.
  """

  alias SymphonyElixir.AgentEvents

  @spec render([AgentEvents.agent_summary()], non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          iodata()
  def render(summaries, _terminal_columns, _terminal_rows, _selection_index)
      when is_list(summaries) do
    []
  end
end
