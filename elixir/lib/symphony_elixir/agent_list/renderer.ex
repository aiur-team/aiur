defmodule SymphonyElixir.AgentList.Renderer do
  @moduledoc """
  Pure rendering function for the agent-list pane.

  Takes the current snapshot (running set + alert counts), the terminal
  geometry, the selection state, and pre-resolved metadata strings.
  Returns iodata ready to be written to stdout.

  Reserves the final terminal column to avoid autowrap on SSH clients
  (the Termius lesson from `status_dashboard.ex`'s history). Uses cursor
  `home` (`\\e[H`) plus per-line `\\e[K` (clear-to-end-of-line) rather
  than `\\e[2J` so the terminal doesn't blank the whole screen between
  frames — that produces visible flashing even when content is stable.
  """

  alias SymphonyElixir.AgentEvents

  # Column widths for the running-agent table.
  @agent_id_width 8
  @agent_status_width 12
  @agent_alerts_width 6

  # ANSI palette.
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_green IO.ANSI.green()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_red IO.ANSI.red()
  @ansi_gray IO.ANSI.light_black()

  @type state :: %{
          summaries: [AgentEvents.agent_summary()],
          selection_index: non_neg_integer(),
          columns: pos_integer(),
          rows: pos_integer(),
          project_label: String.t() | nil,
          dashboard_url: String.t() | nil,
          refresh_label: String.t() | nil
        }

  @spec render(state()) :: iodata()
  def render(state) when is_map(state) do
    cols = Map.get(state, :columns, 80)
    rows = Map.get(state, :rows, 24)
    inner_width = max(cols - 1, 1)

    [
      "\e[H",
      title_row(inner_width),
      eol(),
      metadata_rows(state, inner_width),
      separator_row(inner_width),
      eol(),
      table_header_row(inner_width),
      eol(),
      table_separator_row(inner_width),
      eol(),
      render_rows(Map.get(state, :summaries, []), Map.get(state, :selection_index, 0), inner_width),
      bottom_border(inner_width),
      eol(),
      footer_row(inner_width),
      eol(),
      clear_remaining(rows, lines_emitted(state))
    ]
  end

  # ---------- header / metadata ---------------------------------------------

  defp title_row(inner_width) do
    text = "╭─ SYMPHONY STATUS"
    pad_with_ansi(@ansi_bold, text, inner_width)
  end

  defp metadata_rows(state, inner_width) do
    [
      project_row(Map.get(state, :project_label), inner_width),
      eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
      eol(),
      refresh_row(Map.get(state, :refresh_label), inner_width),
      eol()
    ]
  end

  defp project_row(nil, inner_width), do: metadata_row_iolist("Project:", "n/a", @ansi_gray, inner_width)
  defp project_row("", inner_width), do: metadata_row_iolist("Project:", "n/a", @ansi_gray, inner_width)
  defp project_row(label, inner_width), do: metadata_row_iolist("Project:", label, @ansi_cyan, inner_width)

  defp dashboard_row(nil, inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", @ansi_gray, inner_width)

  defp dashboard_row("", inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", @ansi_gray, inner_width)

  defp dashboard_row(url, inner_width),
    do: metadata_row_iolist("Dashboard:", url, @ansi_cyan, inner_width)

  defp refresh_row(nil, inner_width),
    do: metadata_row_iolist("Next refresh:", "n/a", @ansi_gray, inner_width)

  defp refresh_row("", inner_width),
    do: metadata_row_iolist("Next refresh:", "n/a", @ansi_gray, inner_width)

  defp refresh_row(label, inner_width),
    do: metadata_row_iolist("Next refresh:", label, @ansi_cyan, inner_width)

  defp metadata_row_iolist(label, value, value_color, inner_width) do
    prefix = "│ "
    bold_label = @ansi_bold <> label <> @ansi_reset
    colored_value = value_color <> value <> @ansi_reset
    plain = prefix <> label <> " " <> value
    pad = padding_for(plain, inner_width)
    [prefix, bold_label, " ", colored_value, pad]
  end

  defp separator_row(inner_width) do
    [pad_with_ansi(@ansi_gray, "├" <> String.duplicate("─", max(inner_width - 1, 0)), inner_width)]
  end

  defp bottom_border(inner_width) do
    [pad_with_ansi(@ansi_gray, "╰" <> String.duplicate("─", max(inner_width - 1, 0)), inner_width)]
  end

  defp footer_row(inner_width) do
    text = "  ↑/↓ select   enter/space open   q quit"
    pad_with_ansi(@ansi_dim, text, inner_width)
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width) do
    cells =
      [
        cell("ID", @agent_id_width),
        cell("STATUS", @agent_status_width),
        cell("ALERTS", @agent_alerts_width)
      ]
      |> Enum.intersperse("  ")

    body = ["│   ", cells]
    pad_with_ansi(@ansi_gray, IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width) do
    width =
      @agent_id_width + 2 + @agent_status_width + 2 + @agent_alerts_width

    body = "│   " <> String.duplicate("─", max(min(width, inner_width - 4), 0))
    pad_with_ansi(@ansi_gray, body, inner_width)
  end

  defp render_rows([], _idx, inner_width) do
    [
      pad_with_ansi(@ansi_dim, "│   (no agents running)", inner_width),
      eol()
    ]
  end

  defp render_rows(summaries, idx, inner_width) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {summary, row_idx} ->
      [render_row(summary, row_idx == idx, inner_width), eol()]
    end)
  end

  defp render_row(%{identifier: id, status: status, alert_count: count}, selected?, inner_width) do
    marker = if selected?, do: "▶ ", else: "  "
    status_str = status |> to_string()
    alerts_str = if is_integer(count) and count > 0, do: Integer.to_string(count), else: "—"

    id_cell = cell(id, @agent_id_width)
    status_cell = cell(status_str, @agent_status_width)
    alerts_cell = cell(alerts_str, @agent_alerts_width)

    plain = "│ " <> marker <> id_cell <> "  " <> status_cell <> "  " <> alerts_cell

    if String.length(plain) <= inner_width do
      status_color = status_color(status)
      alerts_color = alerts_color(count)

      body = [
        "│ ",
        marker,
        id_cell,
        "  ",
        status_color,
        status_cell,
        @ansi_reset,
        "  ",
        alerts_color,
        alerts_cell,
        @ansi_reset
      ]

      pad = padding_for(plain, inner_width)
      [body, pad]
    else
      truncated = String.slice(plain, 0, inner_width)
      pad = padding_for(truncated, inner_width)
      [truncated, pad]
    end
  end

  defp status_color(:running), do: @ansi_green
  defp status_color(:error), do: @ansi_red
  defp status_color(:paused), do: @ansi_yellow
  defp status_color(:stopped), do: @ansi_gray
  defp status_color(_other), do: @ansi_reset

  defp alerts_color(count) when is_integer(count) and count > 0, do: @ansi_red
  defp alerts_color(_count), do: @ansi_dim

  # ---------- helpers --------------------------------------------------------

  defp cell(value, width) do
    str =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate(width)

    String.pad_trailing(str, width)
  end

  defp truncate(value, width) do
    cond do
      String.length(value) <= width -> value
      width <= 3 -> String.slice(value, 0, width)
      true -> String.slice(value, 0, width - 1) <> "…"
    end
  end

  defp pad_with_ansi(ansi, text, inner_width) do
    safe = String.slice(text, 0, inner_width)
    pad = padding_for(safe, inner_width)
    [ansi, safe, @ansi_reset, pad]
  end

  defp padding_for(text, inner_width) do
    visible = String.length(strip_ansi(text))
    String.duplicate(" ", max(inner_width - visible, 0))
  end

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")
  end

  defp eol, do: ["\e[K", "\r\n"]

  # Approximate count of rows the frame will draw (used for "blank the rest"
  # below the last rendered row so old content doesn't linger when the agent
  # list shrinks). 8 fixed rows + one per summary + 1 for empty state.
  defp lines_emitted(state) do
    summaries = Map.get(state, :summaries, [])
    body_rows = if summaries == [], do: 1, else: length(summaries)
    9 + body_rows
  end

  defp clear_remaining(rows, lines_drawn) do
    remaining = max(rows - lines_drawn - 1, 0)
    Enum.map(1..max(remaining, 0)//1, fn _ -> ["\e[K", "\r\n"] end)
  end
end
