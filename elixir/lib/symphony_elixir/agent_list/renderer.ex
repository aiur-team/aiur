defmodule SymphonyElixir.AgentList.Renderer do
  @moduledoc """
  Pure rendering function for the agent-list pane.

  Takes the current snapshot (running set + alert counts), the terminal
  geometry, and the selection state. Returns iodata ready to be written
  to stdout.

  Reserves the final terminal column to avoid autowrap on SSH clients
  (the Termius lesson from `status_dashboard.ex`'s history).
  """

  alias SymphonyElixir.AgentEvents

  @type state :: %{
          summaries: [AgentEvents.agent_summary()],
          selection_index: non_neg_integer(),
          columns: pos_integer(),
          rows: pos_integer()
        }

  @spec render(state()) :: iodata()
  def render(%{summaries: summaries, selection_index: idx, columns: cols, rows: rows})
      when is_list(summaries) and is_integer(idx) and is_integer(cols) and is_integer(rows) do
    inner_width = max(cols - 1, 1)

    [
      "\e[2J\e[H",
      pad_line("Symphony — Agents", inner_width, :title),
      "\r\n",
      pad_line(String.duplicate("─", inner_width), inner_width, :divider),
      "\r\n",
      render_rows(summaries, idx, inner_width),
      pad_line("↑/↓ select   enter/space open   q quit", inner_width, :footer)
    ]
  end

  defp render_rows([], _idx, inner_width) do
    [pad_line("(no agents running)", inner_width, :empty), "\r\n"]
  end

  defp render_rows(summaries, idx, inner_width) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {summary, row_idx} ->
      [render_row(summary, row_idx == idx, inner_width), "\r\n"]
    end)
  end

  defp render_row(%{identifier: id, status: status, alert_count: count}, selected?, inner_width) do
    marker = if selected?, do: "▶ ", else: "  "
    alert = if count > 0, do: " (#{count})", else: ""
    text = "#{marker}#{id}  [#{status}]#{alert}"
    pad_line(text, inner_width, :row)
  end

  defp pad_line(text, inner_width, _kind) do
    safe_text = String.slice(text, 0, inner_width)
    padding = String.duplicate(" ", inner_width - String.length(safe_text))
    [safe_text, padding]
  end
end
