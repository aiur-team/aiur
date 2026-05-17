defmodule SymphonyPane.Conversation do
  @moduledoc """
  GenServer that threads `Viewport`, `Composer`, and the transcript-tail
  state together for one open conversation pane.

  Subscribes to `"agent:<identifier>"`, monitors Symphony's node via
  `Node.monitor/2`, dispatches keys to `Composer`, renders via `Viewport`.
  Coalesces incoming `{:transcript_event, ...}` messages into 16ms frames
  (`Process.send_after(self(), :flush_render, 16)`) so streaming Codex
  output cannot starve the composer. Keystrokes bypass the coalesce path
  and render immediately.

  De-duplicates broadcast loopback for the user's own optimistic-echo
  messages via the `msg_id` carried on each transcript event.

  Exits cleanly on `{:nodedown, _}` from the Symphony node monitor.

  Scaffold: implementation lands in the pane-subcommand session.
  """

  alias SymphonyElixir.AgentEvents

  @spec start_link(AgentEvents.agent_identifier()) :: GenServer.on_start()
  def start_link(_identifier), do: {:error, :not_implemented}
end
