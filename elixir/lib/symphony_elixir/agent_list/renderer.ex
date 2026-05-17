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

  # Fixed visual widths for the emoji-bearing columns. Emoji glyphs
  # occupy two terminal columns; we render `<emoji><space>` so the
  # visual width is exactly 3 in every terminal we care about.
  @tag_cell_width 3
  @state_cell_width 3
  @min_id_width 4
  @min_age_width 4
  @min_title_width 6

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
    summaries = Map.get(state, :summaries, [])
    layout = compute_layout(summaries, inner_width)

    [
      "\e[H",
      title_row(inner_width),
      eol(),
      metadata_rows(state, inner_width),
      separator_row(inner_width),
      eol(),
      table_header_row(inner_width, layout),
      eol(),
      table_separator_row(inner_width, layout),
      eol(),
      render_rows(summaries, Map.get(state, :selection_index, 0), inner_width, layout),
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
      agents_row(Map.get(state, :agent_kind), Map.get(state, :agent_count), Map.get(state, :max_agents), inner_width),
      eol(),
      project_row(Map.get(state, :project_label), inner_width),
      eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
      eol(),
      refresh_row(Map.get(state, :refresh_label), inner_width),
      eol()
    ]
  end

  defp agents_row(kind, count, max, inner_width)
       when is_integer(count) and is_integer(max) and max > 0 do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    value = "#{kind_value} (#{count}/#{max})"
    metadata_row_iolist("Agents:", value, @ansi_cyan, inner_width)
  end

  defp agents_row(kind, count, _max, inner_width) when is_integer(count) do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    metadata_row_iolist("Agents:", "#{kind_value} (#{count})", @ansi_cyan, inner_width)
  end

  defp agents_row(_kind, _count, _max, inner_width),
    do: metadata_row_iolist("Agents:", "n/a", @ansi_gray, inner_width)

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

  defp table_header_row(inner_width, layout) do
    body = [
      "│   ",
      cell("ID", layout.id_width),
      "  ",
      cell("", @tag_cell_width),
      cell("", @state_cell_width),
      cell("TITLE", layout.title_width),
      "  ",
      cell("AGE", layout.age_width)
    ]

    pad_with_ansi(@ansi_gray, IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width, layout) do
    width =
      layout.id_width + 2 + @tag_cell_width + @state_cell_width +
        layout.title_width + 2 + layout.age_width

    body = "│   " <> String.duplicate("─", max(min(width, inner_width - 4), 0))
    pad_with_ansi(@ansi_gray, body, inner_width)
  end

  defp render_rows([], _idx, inner_width, _layout) do
    [
      pad_with_ansi(@ansi_dim, "│   (no agents running)", inner_width),
      eol()
    ]
  end

  defp render_rows(summaries, idx, inner_width, layout) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {summary, row_idx} ->
      [render_row(summary, row_idx == idx, inner_width, layout), eol()]
    end)
  end

  defp render_row(summary, selected?, inner_width, layout) do
    marker = if selected?, do: "▶ ", else: "  "
    id_str = to_string(Map.get(summary, :identifier) || "")
    tag = Map.get(summary, :tag)
    work_state = Map.get(summary, :work_state, :working)
    title = Map.get(summary, :title) || ""
    age = age_string(summary)

    id_cell = cell(id_str, layout.id_width)
    tag_cell = emoji_cell(tag_emoji(tag), @tag_cell_width)
    state_cell = emoji_cell(state_emoji(work_state), @state_cell_width)
    title_cell = cell(title, layout.title_width)
    age_cell = cell(age, layout.age_width)

    state_color_seq = state_color(work_state)

    body = [
      "│ ",
      marker,
      @ansi_cyan,
      id_cell,
      @ansi_reset,
      "  ",
      tag_cell,
      state_color_seq,
      state_cell,
      @ansi_reset,
      title_cell,
      "  ",
      @ansi_dim,
      age_cell,
      @ansi_reset
    ]

    plain_visual =
      4 + 2 + layout.id_width + 2 + @tag_cell_width + @state_cell_width +
        layout.title_width + 2 + layout.age_width

    pad = String.duplicate(" ", max(inner_width - plain_visual, 0))
    [body, pad]
  end

  defp state_color(:paused), do: @ansi_yellow
  defp state_color("paused"), do: @ansi_yellow
  defp state_color(:error), do: @ansi_red
  defp state_color(_), do: @ansi_green

  # Emoji choices. Earlier "agent:doing" → 🔨 etc — picked so the column
  # reads as a glance, not a label. Unknown / nil tags get a small dot
  # so the column stays the same width as populated rows.
  defp tag_emoji(nil), do: "·"
  defp tag_emoji(""), do: "·"

  defp tag_emoji(tag) when is_binary(tag) do
    case String.replace_prefix(tag, "agent:", "") do
      "todo" -> "⏳"
      "doing" -> "🔨"
      "done" -> "✅"
      "error" -> "❗"
      "human-review" -> "👀"
      "blocked" -> "🚫"
      "review" -> "👀"
      _ -> "·"
    end
  end

  defp tag_emoji(_), do: "·"

  defp state_emoji(:working), do: "🟢"
  defp state_emoji("working"), do: "🟢"
  defp state_emoji(:paused), do: "🟡"
  defp state_emoji("paused"), do: "🟡"
  defp state_emoji(:error), do: "🔴"
  defp state_emoji(_), do: "⚪"

  defp emoji_cell(glyph, width) do
    # `glyph` is a single grapheme that renders as 2 terminal columns.
    # Pad to the cell's *visual* width by emitting (width - 2) spaces.
    pad = String.duplicate(" ", max(width - 2, 0))
    glyph <> pad
  end

  defp age_string(summary) do
    seconds = Map.get(summary, :runtime_seconds) || 0
    turns = Map.get(summary, :turn_count) || 0
    "#{format_duration(seconds)}/#{turns}t"
  end

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3600,
    do: "#{div(seconds, 3600)}h"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 60,
    do: "#{div(seconds, 60)}m"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 0,
    do: "#{seconds}s"

  defp format_duration(_), do: "0s"

  # Compute per-frame column widths so identifiers and age strings only
  # take as much space as they actually need, leaving the rest for the
  # title. Recomputed on every render so a wider pane reflows
  # immediately when tmux resizes.
  defp compute_layout(summaries, inner_width) do
    age_width =
      summaries
      |> Enum.map(fn s -> String.length(age_string(s)) end)
      |> Enum.max(fn -> 0 end)
      |> max(@min_age_width)

    natural_id_width =
      summaries
      |> Enum.map(fn s -> String.length(to_string(Map.get(s, :identifier) || "")) end)
      |> Enum.max(fn -> 0 end)
      |> max(@min_id_width)

    # `│ ` (2) + marker (2) + id + `  ` (2) + tag + state + title + `  ` (2) + age
    fixed_non_id_overhead = 2 + 2 + 2 + @tag_cell_width + @state_cell_width + 2 + age_width

    # Cap id so the row never bleeds past `inner_width` — title still
    # gets at least @min_title_width regardless of identifier length.
    max_id_width = max(inner_width - fixed_non_id_overhead - @min_title_width, @min_id_width)
    id_width = min(natural_id_width, max_id_width)

    title_width = max(inner_width - fixed_non_id_overhead - id_width, @min_title_width)

    %{id_width: id_width, age_width: age_width, title_width: title_width}
  end

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
  # list shrinks). Fixed rows: title, agents, project, dashboard, refresh,
  # separator, table header, table separator, bottom border, footer = 10.
  defp lines_emitted(state) do
    summaries = Map.get(state, :summaries, [])
    body_rows = if summaries == [], do: 1, else: length(summaries)
    10 + body_rows
  end

  defp clear_remaining(rows, lines_drawn) do
    remaining = max(rows - lines_drawn - 1, 0)

    if remaining == 0 do
      # Even at zero we want to clear the trailing row so any leftover
      # content from a previous frame disappears. No newline so we don't
      # scroll the screen up by one.
      ["\e[K"]
    else
      # Emit `remaining - 1` "blank + newline" rows followed by one final
      # blank row with no newline. Writing past the bottom would scroll the
      # screen up by one row each frame, eating the title.
      Enum.map(1..(remaining - 1)//1, fn _ -> ["\e[K", "\r\n"] end) ++ [["\e[K"]]
    end
  end
end
