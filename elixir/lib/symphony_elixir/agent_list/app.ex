defmodule SymphonyElixir.AgentList.App do
  @moduledoc """
  Entry point invoked by `SymphonyElixir.CLI.main(["agents" | _])`.

  Subscribes to `"agents:running"` and `"agents:status"` via
  `SymphonyElixir.AgentPubSub`, threads the renderer and the input loop
  together, and attaches to the tmux control client so it can react to
  pane-lifecycle events.

  Scaffold: implementation lands with the agent-list pane.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: {:error, :not_implemented}
end
