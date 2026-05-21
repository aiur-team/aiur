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

  # Width of the gap between the ID and AGE columns. Wide enough to
  # center the open-pane glyph (`<space><glyph><space>`) so it doesn't
  # crowd either neighbouring column.
  @id_age_gap_width 3

  # Single-grapheme circle that sits in the gap between the ID and AGE
  # columns to signal that an agent has an open conversation pane.
  # Picked from Geometric Shapes (U+25CF) so monospace fonts render it
  # as 1 terminal column — same family as the ▶ selection marker, and
  # not an emoji (no variation-selector surprises).
  @open_pane_glyph "●"

  # ANSI palette.
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_gray IO.ANSI.light_black()
  @ansi_red IO.ANSI.red()
  @ansi_reverse IO.ANSI.reverse()

  @type state :: %{
          required(:summaries) => [AgentEvents.agent_summary()],
          required(:selection_index) => non_neg_integer(),
          optional(:selection_focus) => :agents | :max_agents,
          required(:columns) => pos_integer(),
          required(:rows) => pos_integer(),
          required(:project_label) => String.t() | nil,
          required(:dashboard_url) => String.t() | nil,
          required(:refresh_label) => String.t() | nil
        }

  @spec render(state()) :: iodata()
  def render(state) when is_map(state) do
    cols = Map.get(state, :columns, 80)
    rows = Map.get(state, :rows, 24)
    inner_width = max(cols - 1, 1)

    if Map.get(state, :help_visible?, false) do
      render_help(inner_width, rows, state)
    else
      # Summaries arrive pre-filtered and pre-sorted from Aiur.AgentList.App
      # so that the visual row order matches the index used by :activate.
      summaries = Map.get(state, :summaries, [])

      layout = compute_layout(summaries, inner_width)

      [
        # Hide the terminal cursor for every render — without this the
        # cursor flashes around the pane as we redraw each row, which
        # reads as visual jitter to the user. `\e[?25l` is DECTCEM hide.
        # Restored on shutdown by Aiur.AgentList.Input.terminate/2.
        "\e[?25l",
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
        render_rows(
          summaries,
          Map.get(state, :selection_index, 0),
          Map.get(state, :selection_focus, :agents),
          inner_width,
          layout,
          visible_identifiers(state)
        ),
        bottom_border(inner_width),
        eol(),
        footer_iodata(inner_width),
        eol(),
        clear_remaining(rows, lines_emitted(state, inner_width))
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
         "enter        open conversation for selected agent",
         "space        pause/resume selected agent",
         "v            toggle pane layout (horizontal ↔ vertical)",
         "?            toggle this help screen",
         "q            quit the agent list"
       ]},
      {"State circle",
       [
         "🟢  agent actively working",
         "⏸️  agent paused by operator",
         "🔴  agent in error state",
         "🏁  agent fully finished",
         "⚫  agent waiting (queued, idle, or label only)"
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

  defp refresh_chip(nil), do: "🔄 in 0s"
  defp refresh_chip(""), do: "🔄 in 0s"
  defp refresh_chip(label) when is_binary(label), do: "🔄 in " <> label

  defp metadata_rows(state, inner_width) do
    [
      agents_row(
        Map.get(state, :agent_kind),
        Map.get(state, :agent_count),
        Map.get(state, :max_agents),
        Map.get(state, :selection_focus) == :max_agents,
        Map.get(state, :max_agents_alert?) == true,
        inner_width
      ),
      eol(),
      project_row(Map.get(state, :project_label), inner_width),
      eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
      eol()
    ]
  end

  defp agents_row(kind, count, max, focused?, alert?, inner_width)
       when is_integer(count) and is_integer(max) and max > 0 do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    agents_row_iolist(kind_value, count, max, focused?, alert?, inner_width)
  end

  defp agents_row(kind, count, _max, _focused?, _alert?, inner_width) when is_integer(count) do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    metadata_row_iolist("Agents:", "#{kind_value} (#{count})", @ansi_cyan, inner_width)
  end

  defp agents_row(_kind, _count, _max, _focused?, _alert?, inner_width),
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

  defp agents_row_iolist(kind, count, max, focused?, alert?, inner_width) do
    label = "Agents:"
    prefix = "│ "
    bold_label = @ansi_bold <> label <> @ansi_reset
    max_text = if focused?, do: "[#{max}]", else: to_string(max)
    affordance = if focused?, do: "  ← →", else: ""
    plain = "#{prefix}#{label} #{kind} (#{count}/#{max_text})#{affordance}"
    pad = padding_for(plain, inner_width)

    max_style =
      cond do
        alert? -> @ansi_red <> @ansi_reverse
        focused? -> @ansi_reverse
        true -> @ansi_cyan
      end

    [
      prefix,
      bold_label,
      " ",
      @ansi_cyan,
      kind,
      " (",
      Integer.to_string(count),
      "/",
      max_style,
      max_text,
      @ansi_reset,
      @ansi_cyan,
      ")",
      affordance,
      @ansi_reset,
      pad
    ]
  end

  defp separator_row(inner_width) do
    [pad_with_ansi(@ansi_gray, "├" <> String.duplicate("─", max(inner_width - 1, 0)), inner_width)]
  end

  defp bottom_border(inner_width) do
    [pad_with_ansi(@ansi_gray, "╰" <> String.duplicate("─", max(inner_width - 1, 0)), inner_width)]
  end

  # Footer keybinds. `v layout` rides on the primary row when there's
  # room, otherwise wraps to a second row so we don't truncate the more
  # frequently used keybinds (select/open/pause/help/quit).
  defp footer_iodata(inner_width) do
    full = "  ↑/↓ select   enter open   space pause/resume   v layout   ? help   q quit"

    if visual_width(full) <= inner_width do
      pad_with_ansi(@ansi_dim, full, inner_width)
    else
      primary = "  ↑/↓ select   enter open   space pause/resume   ? help   q quit"
      secondary = "  v layout"

      [
        pad_with_ansi(@ansi_dim, primary, inner_width),
        eol(),
        pad_with_ansi(@ansi_dim, secondary, inner_width)
      ]
    end
  end

  defp footer_line_count(inner_width) do
    full = "  ↑/↓ select   enter open   space pause/resume   v layout   ? help   q quit"
    if visual_width(full) <= inner_width, do: 1, else: 2
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width, layout) do
    body = [
      "│   ",
      cell("ID", layout.id_width),
      String.duplicate(" ", @id_age_gap_width),
      cell("AGE", layout.age_width),
      "  ",
      cell("", @state_cell_width),
      cell("TITLE", layout.title_width)
    ]

    pad_with_ansi(@ansi_gray, IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width, layout) do
    width =
      layout.id_width + @id_age_gap_width + layout.age_width + 2 + @state_cell_width +
        layout.title_width

    body = "│   " <> String.duplicate("─", max(min(width, inner_width - 4), 0))
    pad_with_ansi(@ansi_gray, body, inner_width)
  end

  defp render_rows([], _idx, _selection_focus, inner_width, _layout, _open_pane_ids) do
    [
      pad_with_ansi(@ansi_dim, "│   (no agents running)", inner_width),
      eol()
    ]
  end

  defp render_rows(summaries, idx, selection_focus, inner_width, layout, open_pane_ids) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {summary, row_idx} ->
      [
        render_row(
          summary,
          selection_focus == :agents and row_idx == idx,
          inner_width,
          layout,
          open_pane_ids
        ),
        eol()
      ]
    end)
  end

  defp render_row(summary, selected?, inner_width, layout, open_pane_ids) do
    marker = if selected?, do: "▶ ", else: "  "
    id_str = to_string(Map.get(summary, :identifier) || "")
    title = Map.get(summary, :title) || ""
    age = age_string(summary)

    id_cell = cell(id_str, layout.id_width)
    age_cell = cell(age, layout.age_width)
    state_cell = emoji_cell(summary_emoji(summary), @state_cell_width)
    title_cell = cell(title, layout.title_width)
    open_marker = open_pane_marker(id_str, open_pane_ids)

    # Order: marker, ID, open-pane indicator, AGE, state-circle, TITLE.
    # The single-glyph circle sits in the gap between ID and AGE so the
    # operator can tell at a glance which agents already own a
    # conversation pane in the grid.
    body = [
      "│ ",
      marker,
      @ansi_cyan,
      id_cell,
      @ansi_reset,
      open_marker,
      @ansi_dim,
      age_cell,
      @ansi_reset,
      "  ",
      state_cell,
      title_cell
    ]

    plain_visual =
      4 + 2 + layout.id_width + @id_age_gap_width + layout.age_width + 2 + @state_cell_width +
        layout.title_width

    pad = String.duplicate(" ", max(inner_width - plain_visual, 0))
    [body, pad]
  end

  # 3-cell separator between ID and AGE columns. Renders as `" ● "` when
  # the identifier has an open pane (glyph centered in the gap), `"   "`
  # otherwise — keeps the column width stable so the AGE column never
  # shifts. Glyph is plain (terminal-default white) so it pops against
  # the surrounding dim text without re-using the green status palette.
  # The circle in front of an identifier indicates "this agent's session
  # is currently visible somewhere in the conversation grid." Source:
  # the `visible_sessions` map populated by AgentList.App from Slot
  # workers' `:slot_session_changed` PubSub broadcasts.
  defp visible_identifiers(state) do
    state
    |> Map.get(:visible_sessions, %{})
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp open_pane_marker(id_str, open_pane_ids) do
    if MapSet.member?(open_pane_ids, id_str) do
      [" ", @open_pane_glyph, " "]
    else
      String.duplicate(" ", @id_age_gap_width)
    end
  end

  # The state column reflects both the workflow tag *and* whether a
  # Aiur agent slot is currently running this ticket:
  # State emoji is driven by the worker's live `work_state` so the agent
  # list paints the same status the conversation pane shows in its
  # header. Both surfaces share `AgentEvents.state_emoji/1`.
  #
  #   running + :working           → 🟢 green   (actively working)
  #   running + :paused            → ⏸️  pause  (paused by operator)
  #   running + :error             → 🔴 red     (agent reported error)
  #   queued  (no slot allocated)  → ⚫ grey
  defp summary_emoji(%{status: :queued}), do: "⚫"

  defp summary_emoji(%{status: :running} = summary) do
    AgentEvents.state_emoji(Map.get(summary, :work_state))
  end

  defp summary_emoji(_), do: "⚫"

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

    # `│ ` (2) + marker (2) + id + `   ` (3 gap) + age + `  ` (2) + state +
    # title
    fixed_non_id_overhead = 2 + 2 + @id_age_gap_width + age_width + 2 + @state_cell_width

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
  # dashboard, separator, table header, table separator, bottom border
  # = 8. Footer is 1 or 2 rows depending on width. Body rows come
  # straight from state.summaries since `Aiur.AgentList.App` now
  # pre-filters the list before passing it in.
  defp lines_emitted(state, inner_width) do
    summaries = Map.get(state, :summaries, [])
    body_rows = if summaries == [], do: 1, else: length(summaries)
    8 + footer_line_count(inner_width) + body_rows
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
