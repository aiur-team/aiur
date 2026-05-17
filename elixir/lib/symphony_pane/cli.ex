defmodule SymphonyPane.CLI do
  @moduledoc """
  Entry point for the conversation-pane subcommand.

  Invoked as `bin/symphony conversation <agent-identifier>` from a tmux pane.
  Steps:
    1. Read the target node from `SYMPHONY_NODE` env var.
    2. Start `:phoenix_pubsub` (the full Symphony app is NOT started here).
    3. `Node.connect/1` and `Node.monitor/2` the main BEAM.
    4. Call `SymphonyElixir.Conversations.attach/1` to subscribe to the
       agent's events.
    5. Hand control to `SymphonyPane.Conversation`.

  Scaffold: bootstrap and rendering implementation come together in a
  follow-up session.
  """

  @spec main([String.t()]) :: no_return()
  def main(_argv), do: System.halt(0)
end
