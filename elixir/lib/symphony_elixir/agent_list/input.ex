defmodule SymphonyElixir.AgentList.Input do
  @moduledoc """
  Stdio owner for the agent-list pane: keystroke loop, CSI escape parser,
  selection state, dispatch to `SymphonyElixir.Tmux.spawn_pane_for/1` on
  enter or space.

  Replaces the existing `SymphonyElixir.TerminalInput`. The CSI parser is
  copied from `terminal_input.ex:256-305` to preserve its behavior for
  arrow keys and bracketed paste handling.

  Scaffold: API placeholder; implementation lands with the agent-list pane.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: {:error, :not_implemented}
end
