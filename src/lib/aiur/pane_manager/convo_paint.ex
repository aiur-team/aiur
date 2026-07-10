defmodule Aiur.PaneManager.ConvoPaint do
  @moduledoc """
  Polls the opencode-attach pane for the conversation-render marker.
  Runs in a spawned Task; emits a Perf event when the marker appears
  or when the polling budget is exhausted.
  """

  alias Aiur.PaneManager.State
  alias Aiur.Tmux

  # Poll every 100 ms and give up after 30 s. The 30 s budget covers
  # cold-start scenarios where the Node.js runtime takes a while to
  # boot. The 100 ms interval keeps the "opencode render" latency number
  # accurate without hammering tmux.
  @convo_paint_poll_interval_ms 100
  @convo_paint_budget_ms 30_000

  @spec detect_convo_first_paint(
          pid(),
          GenServer.server(),
          State.agent_id(),
          pos_integer(),
          State.pane_id()
        ) :: :ok
  def detect_convo_first_paint(pm, tmux, identifier, slot_index, pane_id) do
    started_at = System.monotonic_time(:millisecond)
    deadline = started_at + @convo_paint_budget_ms

    do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline)
  end

  defp do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline) do
    case Tmux.command(tmux, "capture-pane -p -t #{pane_id}") do
      {:ok, lines} ->
        content = Enum.join(lines, "\n")

        if String.contains?(content, "Build · issue-") do
          wall_ms = System.monotonic_time(:millisecond) - started_at

          Aiur.Perf.event(:convo_first_paint,
            identifier: identifier,
            slot: slot_index,
            pane_id: pane_id,
            wall_ms: wall_ms
          )

          send(pm, {:convo_first_paint, identifier, pane_id, wall_ms})
        else
          wait_and_retry_convo_paint(
            pm,
            tmux,
            identifier,
            slot_index,
            pane_id,
            started_at,
            deadline
          )
        end

      _ ->
        wait_and_retry_convo_paint(
          pm,
          tmux,
          identifier,
          slot_index,
          pane_id,
          started_at,
          deadline
        )
    end
  end

  defp wait_and_retry_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      wall_ms = System.monotonic_time(:millisecond) - started_at

      Aiur.Perf.event(:convo_first_paint_timeout,
        identifier: identifier,
        slot: slot_index,
        pane_id: pane_id,
        wall_ms: wall_ms
      )
    else
      Process.sleep(@convo_paint_poll_interval_ms)

      do_detect_convo_paint(pm, tmux, identifier, slot_index, pane_id, started_at, deadline)
    end
  end
end
