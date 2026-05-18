defmodule Aiur.AgentList.Renderer do
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

  alias Aiur.AgentEvents

  # Fixed visual width for the state-emoji column. The glyph occupies
  # two terminal columns; we render `<emoji><space>` so the cell is
  # exactly 3 wide in every terminal we care about.
  @state_cell_width 3
  @min_id_width 4
  @min_age_width 4
  @min_title_width 6

  # ANSI palette.
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
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

    if Map.get(state, :help_visible?, false) do
      render_help(inner_width, rows, state)
    else
      summaries =
        state
        |> Map.get(:summaries, [])
        |> filter_visible_summaries()
        |> sort_summaries()

      layout = compute_layout(summaries, inner_width)

      [
        "\e[H",
        title_row(inner_width, Map.get(state, :refresh_label)),
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
  end

  # Help overlay reusing the same bordered chrome as the main view.
  # Lists the keybinds and the state-circle legend so an operator new
  # to the agent-list pane can self-orient.
  defp render_help(inner_width, rows, state) do
    body_rows = help_body_rows(inner_width)
    body_count = length(body_rows)

    drawn =
      [
        "\e[H",
        title_row(inner_width, Map.get(state, :refresh_label)),
        eol(),
        separator_row(inner_width),
        eol()
      ] ++
        Enum.flat_map(body_rows, fn row -> [row, eol()] end) ++
        [
          bottom_border(inner_width),
          eol(),
          help_footer_row(inner_width),
          eol()
        ]

    # 5 fixed chrome rows (title, separator, bottom border, footer) +
    # 1 newline after each + the help body rows.
    drawn_count = 4 + body_count
    drawn ++ [clear_remaining(rows, drawn_count)]
  end

  defp help_body_rows(inner_width) do
    sections = [
      {"Keybinds",
       [
         "↑ / k        select previous",
         "↓ / j        select next",
         "enter, space open conversation for selected agent",
         "?            toggle this help screen",
         "q            quit the agent list"
       ]},
      {"State circle",
       [
         "🟢  agent running, label is agent:in-progress",
         "🟡  agent running, label is agent:todo (queued for codex)",
         "🟡  agent paused (label override)",
         "🟣  agent running, label is agent:human-review",
         "🟠  agent running, label is agent:rework",
         "🔵  agent running, label is agent:merging",
         "🔴  agent in error state",
         "⚫  agent:* label present but no Aiur slot allocated yet"
       ]},
      {"Tips",
       [
         "Open multiple agents in panes to watch them in parallel.",
         "Tickets cycle through 5 conversation slots; #6 replaces #1.",
         "Press `?` again or `q` to leave this help screen."
       ]}
    ]

    sections
    |> Enum.flat_map(fn {heading, lines} ->
      [help_heading_row(heading, inner_width)] ++
        Enum.map(lines, fn line -> help_line_row(line, inner_width) end) ++
        [help_blank_row(inner_width)]
    end)
    |> Enum.drop(-1)
  end

  defp help_heading_row(text, inner_width) do
    prefix = "│ "
    bold = @ansi_bold <> text <> @ansi_reset
    plain = prefix <> text
    pad = padding_for(plain, inner_width)
    [prefix, bold, pad]
  end

  defp help_line_row(text, inner_width) do
    prefix = "│   "
    plain = prefix <> text
    pad_width = max(inner_width - visual_width(plain), 0)
    pad = String.duplicate(" ", pad_width)
    [prefix, text, pad]
  end

  defp help_blank_row(inner_width) do
    pad = String.duplicate(" ", max(inner_width - 1, 0))
    ["│", pad]
  end

  defp help_footer_row(inner_width) do
    text = "  ? close help   q quit"
    pad_with_ansi(@ansi_dim, text, inner_width)
  end

  # ---------- header / metadata ---------------------------------------------

  defp title_row(inner_width, refresh_label) do
    title = "╭─ AIUR STATUS"
    refresh = refresh_chip(refresh_label)
    refresh_visual = visual_width(refresh)
    title_visual = visual_width(title)

    pad_count = max(inner_width - title_visual - refresh_visual, 1)
    pad = String.duplicate(" ", pad_count)

    # Title bolds the AIUR STATUS text; the refresh chip stays
    # cyan with a leading 🔄 emoji so the eye lands on the live state
    # indicator on the right. The plain ASCII "in" word keeps the
    # phrase readable in any terminal palette.
    [@ansi_bold, title, @ansi_reset, pad, @ansi_cyan, refresh, @ansi_reset]
  end

  defp refresh_chip(nil), do: "🔄 n/a"
  defp refresh_chip(""), do: "🔄 n/a"
  defp refresh_chip(label) when is_binary(label), do: "🔄 in " <> label

  defp metadata_rows(state, inner_width) do
    [
      agents_row(
        Map.get(state, :agent_kind),
        Map.get(state, :agent_count),
        Map.get(state, :max_agents),
        inner_width
      ),
      eol(),
      project_row(Map.get(state, :project_label), inner_width),
      eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
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
    text = "  ↑/↓ select   enter/space open   ? help   q quit"
    pad_with_ansi(@ansi_dim, text, inner_width)
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width, layout) do
    body = [
      "│   ",
      cell("ID", layout.id_width),
      "  ",
      cell("AGE", layout.age_width),
      "  ",
      cell("", @state_cell_width),
      cell("TITLE", layout.title_width)
    ]

    pad_with_ansi(@ansi_gray, IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width, layout) do
    width =
      layout.id_width + 2 + layout.age_width + 2 + @state_cell_width + layout.title_width

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
    title = Map.get(summary, :title) || ""
    age = age_string(summary)

    id_cell = cell(id_str, layout.id_width)
    age_cell = cell(age, layout.age_width)
    state_cell = emoji_cell(summary_emoji(summary), @state_cell_width)
    title_cell = cell(title, layout.title_width)

    # Order: marker, ID, AGE, state-circle, TITLE. The state circle
    # (🟢 / 🟡 / 🔴) is the one signal we keep next to the title —
    # the workflow-tag emoji was redundant with the title text.
    body = [
      "│ ",
      marker,
      @ansi_cyan,
      id_cell,
      @ansi_reset,
      "  ",
      @ansi_dim,
      age_cell,
      @ansi_reset,
      "  ",
      state_cell,
      title_cell
    ]

    plain_visual =
      4 + 2 + layout.id_width + 2 + layout.age_width + 2 + @state_cell_width +
        layout.title_width

    pad = String.duplicate(" ", max(inner_width - plain_visual, 0))
    [body, pad]
  end

  # The state column reflects both the workflow tag *and* whether a
  # Aiur agent slot is currently running this ticket:
  #
  #   running + agent:todo         → 🟡 yellow
  #   running + agent:in-progress  → 🟢 green
  #   running + agent:human-review → 🟣 purple
  #   running + agent:rework       → 🟠 orange
  #   running + agent:merging      → 🔵 blue
  #   running + paused (any tag)   → 🟡 yellow (override)
  #   running + error (any tag)    → 🔴 red    (override)
  #   queued  (any tag, no slot)   → ⚫ grey
  #
  # The grey is intentional: a ticket carrying an `agent:*` label
  # without an active slot reads as "waiting" at a glance.
  # Drop cancelled/canceled tickets from the visible list — terminal
  # state with no further conversation. Done tickets are also hidden
  # for now (talking to a done agent has no listener); revisit if we
  # add a "reopen / continue" flow later.
  defp filter_visible_summaries(summaries) do
    Enum.reject(summaries, fn s ->
      tag = Map.get(s, :tag)
      tag in ["agent:cancelled", "agent:canceled", "agent:done"]
    end)
  end

  # Running first, then queued; each group sorted by identifier ascending
  # so the row order stays stable across refreshes.
  defp sort_summaries(summaries) do
    Enum.sort_by(summaries, fn s ->
      bucket =
        case Map.get(s, :status) do
          :running -> 0
          :queued -> 1
          _ -> 2
        end

      {bucket, to_string(Map.get(s, :identifier) || "")}
    end)
  end

  defp summary_emoji(%{status: :queued}), do: "⚫"

  defp summary_emoji(%{status: :running} = summary) do
    case Map.get(summary, :work_state) do
      :paused -> "🟡"
      "paused" -> "🟡"
      :error -> "🔴"
      _ -> tag_color_emoji(Map.get(summary, :tag))
    end
  end

  defp summary_emoji(_), do: "⚫"

  defp tag_color_emoji(nil), do: "⚫"
  defp tag_color_emoji(""), do: "⚫"

  defp tag_color_emoji(tag) when is_binary(tag) do
    case String.replace_prefix(tag, "agent:", "") do
      "todo" -> "🟡"
      "in-progress" -> "🟢"
      "human-review" -> "🟣"
      "rework" -> "🟠"
      "merging" -> "🔵"
      _ -> "⚫"
    end
  end

  defp tag_color_emoji(_), do: "⚫"

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

    # `│ ` (2) + marker (2) + id + `  ` (2) + age + `  ` (2) + state +
    # title
    fixed_non_id_overhead = 2 + 2 + 2 + age_width + 2 + @state_cell_width

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

  # Visual column width of `text`, counting each grapheme heavier than
  # one byte as occupying two terminal columns. That matches how every
  # mainstream terminal renders emoji and CJK glyphs.
  defp visual_width(text) when is_binary(text) do
    text
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  defp grapheme_width(g) when byte_size(g) > 1, do: 2
  defp grapheme_width(_g), do: 1

  defp strip_ansi(text) do
    Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")
  end

  defp eol, do: ["\e[K", "\r\n"]

  # Approximate count of rows the frame will draw (used for "blank the
  # rest" below the last rendered row so old content doesn't linger
  # when the agent list shrinks). Fixed rows: title, agents, project,
  # dashboard, separator, table header, table separator, bottom border,
  # footer = 9. Body rows must reflect the *visible* summaries — i.e.
  # after `filter_visible_summaries/1` — otherwise hidden tickets
  # inflate the count and leave a stale footer row on screen.
  defp lines_emitted(state) do
    visible =
      state
      |> Map.get(:summaries, [])
      |> filter_visible_summaries()

    body_rows = if visible == [], do: 1, else: length(visible)
    9 + body_rows
  end

  defp clear_remaining(rows, lines_drawn) do
    if lines_drawn >= rows do
      # Already at or past the bottom — nothing left to clear.
      []
    else
      # Absolute-position the cursor to the row directly below the last
      # rendered row and clear from there to the end of the screen. Using
      # `\e[J` (clear-from-cursor-to-end) is robust against off-by-one
      # row counts that would otherwise leave a stale row at the very
      # bottom (the duplicate-footer bug). No `\r\n` involved, so we
      # never trigger a terminal scroll either.
      [["\e[", Integer.to_string(lines_drawn + 1), ";1H"], "\e[J"]
    end
  end
end
