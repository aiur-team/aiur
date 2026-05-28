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
  alias Aiur.Opencode.WarmthReport
  alias Aiur.ProgressTracker

  # Fixed visual width for the state-emoji column. The glyph occupies
  # two terminal columns; we render `<emoji><space>` so the cell is
  # exactly 3 wide in every terminal we care about.
  @state_cell_width 3

  # Reserved slot to the right of the status emoji for the `❗` (or
  # `❗N`) attention indicator. Always allocated even when no
  # attention is open, so the Latest column never shifts when state
  # flips. 4 columns: emoji (2 terminal columns) + up to one digit +
  # trailing space.
  @attention_cell_width 4

  # Maximum width allotted to the Latest column. The column takes
  # remaining inner width up to this cap; if there's less room
  # available, the column shrinks (and the message truncates with `…`).
  @max_latest_width 60
  @min_latest_width 0

  # Fixed-width progress bar + ETA columns. Sized so they always
  # render regardless of terminal width (collapse Latest first).
  # Layout: `<bar 8> <eta 5>` = 8 + 1 + 5 = 14 cols.
  @progress_bar_width 8
  @eta_width 5
  @progress_cell_width 14

  @min_id_width 4
  @min_age_width 4
  @min_title_width 6
  # When the terminal can't fit the full natural title + Latest at
  # @max_latest_width, cap the title at this many chars so other
  # columns aren't pushed off screen. With a wide enough terminal,
  # the constraint doesn't trigger and the title renders in full.
  @title_constrained_cap 25

  @id_age_gap_width 2

  # Warm-status row glyphs, shown beneath the bottom nav. One glyph
  # per opencode slot. Dark-mode pair is the default; light mode is
  # opt-in via `warm_status_dark_mode?: false` in render state.
  @warm_status_glyph_dark_in_progress "🔲"
  @warm_status_glyph_dark_finished "⬜️"
  @warm_status_glyph_light_in_progress "🔳"
  @warm_status_glyph_light_finished "⬛️"

  # ANSI palette.
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_gray IO.ANSI.light_black()
  @ansi_red IO.ANSI.red()
  @ansi_reverse IO.ANSI.reverse()
  # 256-color background for the selected agent-list row. 236 is a
  # dark grey one or two shades lighter than the default terminal
  # background — visible enough to mark the row without competing
  # with text colors.
  @ansi_selected_bg "\e[48;5;236m"

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

      layout =
        summaries
        |> compute_layout(inner_width)
        |> Map.put(:open_attentions_by_id, Map.get(state, :open_attentions_by_id, %{}))
        |> Map.put(:latest_event_by_id, Map.get(state, :latest_event_by_id, %{}))
        |> Map.put(:attach_state, Map.get(state, :attach_state, %{}))
        |> Map.put(:agents_with_content, Map.get(state, :agents_with_content, MapSet.new()))
        |> Map.put(:now_ms, System.monotonic_time(:millisecond))

      debug_footer = debug_perf_footer(state, inner_width)
      markers = compute_markers(state, summaries)
      warm_row = warm_status_row(state, inner_width)

      base_lines =
        lines_emitted(state, inner_width) + debug_footer_line_count(state) +
          warm_row_line_count(state)

      # Reserve at least one row of breathing room before the bottom of
      # the pane so the ticker never overflows tmux's scroll region. If
      # there's no room left, render nothing.
      ticker_budget = max(rows - base_lines - 1, 0)
      {ticker_iodata, ticker_line_count} = debug_events_ticker(state, inner_width, ticker_budget)

      [
        # Cursor controls at frame start:
        #   `\e[?25l`  hide cursor
        #   `\e[?12l`  disable cursor blinking (some terminals show
        #              the cursor "phantom" via blink even when set
        #              to hidden via `?25l`; killing blink prevents
        #              that)
        #   `\e[H`     park at home so any brief visibility (during
        #              the write itself) lands at row 1 col 1
        # The same triplet repeats at the END of the frame to
        # counter any other process or tmux event that might have
        # re-enabled the cursor between frames.
        "\e[?25l",
        "\e[?12l",
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
          markers
        ),
        bottom_border(inner_width),
        eol(),
        footer_iodata(inner_width),
        eol(),
        warm_row,
        debug_footer,
        ticker_iodata,
        clear_remaining(rows, base_lines + ticker_line_count),
        # Re-emit hide + no-blink + park-home AFTER all painting,
        # so any tmux refresh, focus change, or sibling process
        # that flipped the cursor back on gets countered on every
        # render tick. Multiple consecutive emits are no-ops; the
        # cost is six bytes per tick.
        "\e[?25l",
        "\e[?12l",
        "\e[H"
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
         "⏳  warming up — pane not yet ready",
         "🟢  agent actively working — pane ready to open",
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
    pad_with_ansi(@ansi_dim, text, inner_width, " ")
  end

  # ---------- header / metadata ---------------------------------------------

  defp title_row(inner_width, refresh_label) do
    title = "╭─ AIUR"
    refresh = refresh_chip(refresh_label)
    refresh_visual = visual_width(refresh)
    title_visual = visual_width(title)

    # `╮` rounded corner reserved at the far right; padding fills the
    # gap between the AIUR title and the refresh chip + corner.
    pad_count = max(inner_width - title_visual - refresh_visual - 1, 1)
    pad = String.duplicate(" ", pad_count)

    # Title bolds the AIUR text; the refresh chip stays
    # cyan with a leading 🔄 emoji so the eye lands on the live state
    # indicator on the right. The plain ASCII "in" word keeps the
    # phrase readable in any terminal palette.
    [
      @ansi_bold,
      title,
      @ansi_reset,
      pad,
      @ansi_cyan,
      refresh,
      @ansi_reset,
      @ansi_gray,
      "╮",
      @ansi_reset
    ]
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
    [
      pad_with_ansi(
        @ansi_gray,
        "├" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "┤"
      )
    ]
  end

  defp bottom_border(inner_width) do
    [
      pad_with_ansi(
        @ansi_gray,
        "╰" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "╯"
      )
    ]
  end

  # Footer keybinds. `v layout` rides on the primary row when there's
  # room, otherwise wraps to a second row so we don't truncate the more
  # frequently used keybinds (select/open/pause/help/quit).
  defp footer_iodata(inner_width) do
    full = "  ↑/↓ select   enter open   space pause/resume   v layout   ? help   q quit"

    # Footer + help rows render BELOW the bordered agent-list box,
    # so they don't carry the right `│` border. Pass " " as the
    # right_border to keep the column reserved for autowrap safety
    # without painting the bar character.
    if visual_width(full) <= inner_width do
      pad_with_ansi(@ansi_dim, full, inner_width, " ")
    else
      primary = "  ↑/↓ select   enter open   space pause/resume   ? help   q quit"
      secondary = "  v layout"

      [
        pad_with_ansi(@ansi_dim, primary, inner_width, " "),
        eol(),
        pad_with_ansi(@ansi_dim, secondary, inner_width, " ")
      ]
    end
  end

  defp footer_line_count(inner_width) do
    full = "  ↑/↓ select   enter open   space pause/resume   v layout   ? help   q quit"
    if visual_width(full) <= inner_width, do: 1, else: 2
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width, layout) do
    progress_header =
      if layout.show_progress?, do: [" ", cell("PROGRESS", @progress_cell_width)], else: []

    body = [
      "│   ",
      cell("ID", layout.id_width),
      String.duplicate(" ", @id_age_gap_width),
      cell("AGE", layout.age_width),
      "  ",
      cell("", @state_cell_width),
      cell("", @attention_cell_width),
      cell("TITLE", layout.title_width),
      " ",
      cell("LATEST", layout.latest_width),
      progress_header
    ]

    pad_with_ansi(@ansi_gray, IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width, _layout) do
    # Full-width horizontal rule from `├` to `┤`, matching the
    # other section dividers above and below so the box closes
    # cleanly on both sides. Previously the dashes stopped at the
    # column-totals width and the rest of the row was blank space —
    # the right `│` border ended up disconnected from the divider.
    [
      pad_with_ansi(
        @ansi_gray,
        "├" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "┤"
      )
    ]
  end

  defp render_rows([], _idx, _selection_focus, inner_width, _layout, _markers) do
    [
      pad_with_ansi(@ansi_dim, "│   (no agents running)", inner_width),
      eol()
    ]
  end

  defp render_rows(summaries, idx, selection_focus, inner_width, layout, markers) do
    summaries
    |> Enum.with_index()
    |> Enum.map(fn {summary, row_idx} ->
      [
        render_row(
          summary,
          selection_focus == :agents and row_idx == idx,
          inner_width,
          layout,
          markers
        ),
        eol()
      ]
    end)
  end

  defp render_row(summary, selected?, inner_width, layout, markers) do
    marker = if selected?, do: "▶ ", else: "  "
    id_str = to_string(Map.get(summary, :identifier) || "")
    title = Map.get(summary, :title) || ""
    age = age_string(summary)

    id_cell = id_cell_with_link(id_str, layout)
    age_cell = cell(age, layout.age_width)
    state_cell = emoji_cell(summary_emoji(summary, markers), @state_cell_width)
    attention_cell = attention_cell(id_str, layout)
    title_cell = cell(title, layout.title_width)
    latest_cell = latest_cell(id_str, layout, summary)
    gap = String.duplicate(" ", @id_age_gap_width)

    progress_block =
      if layout.show_progress? do
        [" ", @ansi_dim, progress_cell(id_str, layout), @ansi_reset]
      else
        []
      end

    body = [
      "│ ",
      marker,
      @ansi_cyan,
      id_cell,
      @ansi_reset,
      gap,
      @ansi_dim,
      age_cell,
      @ansi_reset,
      "  ",
      state_cell,
      attention_cell,
      title_cell,
      " ",
      @ansi_dim,
      latest_cell,
      @ansi_reset,
      progress_block
    ]

    progress_width = if layout.show_progress?, do: @progress_cell_width + 1, else: 0

    # Visual columns consumed by the body, in order:
    #   `│ ` (2) + marker (2) + id_cell + gap + age_cell + `  ` (2)
    #   + state_cell (3) + attention_cell (4) + title_cell + ` ` (1)
    #   + latest_cell + progress_block.
    # Sum the parts directly so the right `│` border lands at the
    # same column as the metadata/separator rows above.
    plain_visual =
      2 + 2 + layout.id_width + @id_age_gap_width + layout.age_width + 2 + @state_cell_width +
        @attention_cell_width + layout.title_width + 1 + layout.latest_width + progress_width

    # Reserve the last column for the right `│` border so each row
    # closes cleanly. Pad to (inner_width - 1) then append the bar.
    pad = String.duplicate(" ", max(inner_width - 1 - plain_visual, 0))
    row = [body, pad]

    if selected? do
      # Fill the entire row width with a subtle background so the
      # selected agent is visually obvious end-to-end. Each cell's
      # `\e[0m` reset would otherwise clear the bg mid-row and
      # leave a fragmented highlight; we re-apply
      # `@ansi_selected_bg` immediately after every reset so the
      # bg paints continuously through the whole row.
      painted =
        row
        |> IO.iodata_to_binary()
        |> String.replace(@ansi_reset, @ansi_reset <> @ansi_selected_bg)

      [@ansi_selected_bg, painted, @ansi_reset, @ansi_gray, "│", @ansi_reset]
    else
      [row, @ansi_gray, "│", @ansi_reset]
    end
  end

  # Wrap a padded ID cell in an OSC 8 hyperlink to the ticket's
  # web page when the renderer knows the project (e.g.
  # "its-everdred/aiur") AND the identifier looks like a GitHub
  # issue number. Terminals that support OSC 8 (iTerm2, WezTerm,
  # Ghostty, etc.) render the cell as a click-to-open link; those
  # that don't ignore the escapes and display the digits as plain
  # text. Width calculations are unaffected because OSC sequences
  # have zero visual width.
  defp id_cell_with_link(id_str, layout) do
    padded = cell(id_str, layout.id_width)
    project = Map.get(layout, :project_label)

    case ticket_url(project, id_str) do
      nil -> padded
      url -> "\e]8;;" <> url <> "\e\\" <> padded <> "\e]8;;\e\\"
    end
  end

  defp ticket_url(project, id_str) when is_binary(project) and is_binary(id_str) do
    case Integer.parse(id_str) do
      {n, ""} when n > 0 -> "https://github.com/" <> project <> "/issues/" <> Integer.to_string(n)
      _ -> nil
    end
  end

  defp ticket_url(_project, _id_str), do: nil

  # `❗` cell: blank-but-allocated when zero attentions open; `❗`
  # alone (two terminal columns + space) when one; `❗N` when more.
  # Width stays @attention_cell_width either way so the Latest
  # column never shifts horizontally on flip.
  defp attention_cell(id, layout) do
    count = layout |> Map.get(:open_attentions_by_id, %{}) |> Map.get(id, 0)

    text =
      cond do
        count <= 0 -> ""
        count == 1 -> "❗"
        count >= 10 -> "❗9+"
        true -> "❗#{count}"
      end

    emoji_cell(text, @attention_cell_width)
  end

  # Progress + ETA pair, rendered as one cell of fixed width 14:
  # `<bar 8> <eta 5>`. Empty bar + empty ETA when the tracker has
  # no samples for the id — width stays the same so the column
  # never jitters. No `—` placeholder; the absence is conveyed by
  # the empty bar alone.
  defp progress_cell(id, layout) do
    samples = layout |> Map.get(:progress_by_id, %{}) |> Map.get(id, [])
    now_ms = Map.get(layout, :now_ms, System.monotonic_time(:millisecond))

    {bar, eta_text} =
      case ProgressTracker.estimate(samples, now_ms) do
        :unknown ->
          {ProgressTracker.bar(0, @progress_bar_width), ""}

        %{percent: pct, eta_seconds: eta} ->
          {ProgressTracker.bar(pct, @progress_bar_width), ProgressTracker.format_eta(eta)}
      end

    eta_padded = String.pad_trailing(eta_text, @eta_width)
    bar <> " " <> eta_padded
  end

  # Latest column cell — current most-recent event message for the
  # ticket. When no event has landed yet, shows a phase-aware
  # placeholder with an animated spinner so the row feels alive
  # while the agent is queued/warming/starting. Truncated with `…`
  # when wider than the column.
  defp latest_cell(id, layout, summary) do
    if layout.latest_width <= 0 do
      ""
    else
      text =
        case Map.get(layout, :latest_event_by_id, %{}) |> Map.get(id) do
          nil -> phase_placeholder(id, layout, summary)
          event -> latest_event_message(event)
        end

      cell(text, layout.latest_width)
    end
  end

  # Braille spinner that advances ~10 frames per second so the
  # placeholder reads as "alive" even though our render tick is
  # 1 Hz — `now_ms / 100` rolls through the frame list as the
  # millisecond clock advances. Same frame within a single render
  # because `:now_ms` is captured once at the top of render/1.
  @spinner_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  defp spinner_frame(layout) do
    now_ms = Map.get(layout, :now_ms, System.monotonic_time(:millisecond))
    idx = rem(div(now_ms, 100), length(@spinner_frames))
    Enum.at(@spinner_frames, idx)
  end

  # Decide what phase text to show in the LATEST column when no
  # real event has landed for this agent yet. Mirrors the marker
  # state machine so the placeholder advances visibly as the
  # agent's slot/codex come online.
  defp phase_placeholder(id, layout, summary) do
    spinner = spinner_frame(layout)
    attach = Map.get(layout, :attach_state, %{}) |> Map.get(id)
    has_content = MapSet.member?(Map.get(layout, :agents_with_content, MapSet.new()), id)

    phrase =
      cond do
        Map.get(summary, :status) == :queued -> "Queueing agent…"
        is_nil(attach) -> "Warming up…"
        match?(%{visible_in: nil}, attach) -> "Warming up…"
        not has_content -> "Starting codex…"
        true -> ""
      end

    if phrase == "", do: "", else: spinner <> " " <> phrase
  end

  defp latest_event_message(nil), do: ""
  defp latest_event_message(%{message: msg}) when is_binary(msg), do: msg
  defp latest_event_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp latest_event_message(_), do: ""

  # Per-identifier marker, ordered most-ready-first:
  #
  #   🟢  agent's pane is open in window 0 right now
  #       (`opened_panes`, populated by PaneManager pane_opened/closed events)
  #   ⚪  agent's leadoff slot has finished painting in the hidden window
  #       AND the agent has emitted at least one transcript event —
  #       opening shows meaningful content immediately.
  #       (`attach_state[id].visible_in` is set, AND `id` is in
  #       `agents_with_content`)
  #   🔘  agent's leadoff slot has painted (instant-open) but the codex
  #       turn hasn't produced any transcript content yet — opening
  #       shows just Build chrome and a blank pane until content
  #       streams in. This is the "pre-warmed, agent still warming up"
  #       in-between state.
  #   ⏳  no instant-open path yet: slot hasn't painted (or no slot has
  #       attached this identifier at all). Opening requires a respawn.
  #
  # `agents_with_content` is mirrored from per-agent transcript
  # broadcasts: once any transcript_event fires for an identifier, the
  # AgentList state adds it to this set and the marker promotes ⚪.
  defp compute_markers(state, summaries) do
    attach_state = Map.get(state, :attach_state, %{})
    opened_panes = Map.get(state, :opened_panes, MapSet.new())
    agents_with_content = Map.get(state, :agents_with_content, MapSet.new())

    Enum.reduce(summaries, %{}, fn summary, acc ->
      id = to_string(Map.get(summary, :identifier) || "")

      Map.put(
        acc,
        id,
        marker_for_identifier(id, opened_panes, attach_state, agents_with_content)
      )
    end)
  end

  defp marker_for_identifier(id, opened_panes, attach_state, agents_with_content) do
    if MapSet.member?(opened_panes, id) do
      "🟢"
    else
      marker_from_attach(Map.get(attach_state, id), MapSet.member?(agents_with_content, id))
    end
  end

  defp marker_from_attach(%{visible_in: slot}, true) when not is_nil(slot), do: "⚪"
  defp marker_from_attach(%{visible_in: slot}, _has_content) when not is_nil(slot), do: "🔘"
  defp marker_from_attach(_attach, _has_content), do: "⏳"

  # `summary_emoji` defers to the precomputed marker for running
  # working agents, and to AgentEvents for paused/error/done states.
  defp summary_emoji(%{status: :queued}, _markers), do: "⚫"

  defp summary_emoji(%{status: :running, identifier: identifier} = summary, markers) do
    case Map.get(summary, :work_state) do
      state when state in [:paused, "paused", :error, "error", :done, "done"] ->
        AgentEvents.state_emoji(state)

      _ ->
        Map.get(markers, to_string(identifier), "⏳")
    end
  end

  defp summary_emoji(%{work_state: work_state}, _markers), do: AgentEvents.state_emoji(work_state)
  defp summary_emoji(_, _markers), do: "⚫"

  # Status row beneath the bottom nav. One glyph per started opencode
  # slot: in-progress glyph for slots still warming, finished glyph for
  # slots that have every active agent attached. Geometry stays stable
  # across warm-up (zero glyphs is valid).
  defp warm_status_row(state, inner_width) do
    if warm_status_enabled?(state) do
      build_warm_status_row(state, inner_width)
    else
      []
    end
  end

  defp build_warm_status_row(state, inner_width) do
    started = Map.get(state, :started_slots, MapSet.new())
    finished = Map.get(state, :fully_warmed_slots, MapSet.new())
    {in_progress_glyph, finished_glyph} = warm_status_glyphs(state)

    glyphs = warm_status_glyph_line(started, finished, in_progress_glyph, finished_glyph)
    body = "  " <> glyphs
    [pad_with_ansi(@ansi_dim, body, inner_width, " "), eol()]
  end

  defp warm_status_glyph_line(started, finished, in_progress_glyph, finished_glyph) do
    started
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.map_join(" ", fn slot ->
      warm_status_slot_glyph(slot, finished, in_progress_glyph, finished_glyph)
    end)
  end

  defp warm_status_slot_glyph(slot, finished, in_progress_glyph, finished_glyph) do
    if MapSet.member?(finished, slot), do: finished_glyph, else: in_progress_glyph
  end

  defp warm_status_glyphs(state) do
    if Map.get(state, :warm_status_dark_mode?, true) do
      {@warm_status_glyph_dark_in_progress, @warm_status_glyph_dark_finished}
    else
      {@warm_status_glyph_light_in_progress, @warm_status_glyph_light_finished}
    end
  end

  defp warm_status_row_line_count(state) do
    if warm_status_enabled?(state), do: 1, else: 0
  end

  defp warm_status_enabled?(state) do
    # Bottom warmth row (🔲 starting / ⬜ ready) is a debug-only
    # observability surface, not a user-facing feature. Hidden when
    # AIUR_DEBUG is off so the default agent list stays focused on
    # per-ticket markers. State-level override (`warm_status_row?`)
    # still wins for tests that explicitly want to render it.
    case Map.get(state, :warm_status_row?) do
      nil -> debug_enabled?()
      explicit -> explicit
    end
  end

  defp debug_enabled? do
    case System.get_env("AIUR_DEBUG") do
      v when is_binary(v) -> String.downcase(String.trim(v)) in ["1", "true", "yes"]
      _ -> false
    end
  end

  defp warm_row_line_count(state), do: warm_status_row_line_count(state)

  defp emoji_cell("", width) do
    # Reserved-but-empty cell: pad to the full visual width.
    String.duplicate(" ", max(width, 0))
  end

  defp emoji_cell(glyph, width) do
    # The leading grapheme is a 2-terminal-column emoji; everything
    # after (digits, suffix) is 1 column per char. `❗3` reads as
    # visual_width = 2 + 1 = 3; `❗9+` reads as 2 + 2 = 4. Pad with
    # the remainder so the cell is exactly `width` columns wide.
    visual =
      case String.next_grapheme(glyph) do
        {_first, rest} -> 2 + String.length(rest)
        nil -> 0
      end

    pad = String.duplicate(" ", max(width - visual, 0))
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

    natural_title_width =
      summaries
      |> Enum.map(fn s -> String.length(to_string(Map.get(s, :title) || "")) end)
      |> Enum.max(fn -> 0 end)
      |> max(@min_title_width)

    # `│ ` (2) + marker (2) + id + `   ` (3 gap) + age + `  ` (2) +
    # state (3) + attention (4) + title + ` ` (1) + [progress block]
    # + ` │` (1 for the right border the row closes with).
    # The progress block (14 + 1 = 15) is included when terminal width
    # allows it; on very narrow terminals it collapses to zero.
    base_overhead = 2 + 2 + @id_age_gap_width + age_width + 2 + @state_cell_width + @attention_cell_width + 1
    show_progress? = inner_width - base_overhead - @min_id_width - @min_title_width - 1 >= @progress_cell_width + 1
    progress_block_width = if show_progress?, do: @progress_cell_width + 1, else: 0
    fixed_non_id_overhead = base_overhead + progress_block_width

    # Cap id so the row never bleeds past `inner_width` — title and
    # latest still get their minimums regardless of identifier length.
    max_id_width =
      max(
        inner_width - fixed_non_id_overhead - @min_title_width - @min_latest_width - 1,
        @min_id_width
      )

    id_width = min(natural_id_width, max_id_width)

    # Title gets its natural width when there's room. Latest takes
    # whatever's left (capped at @max_latest_width). When the
    # terminal can't fit both naturally, title caps at
    # @title_constrained_cap (25 chars) — that leaves more room for
    # Latest and avoids long titles pushing other columns off
    # screen. With a wide enough terminal there's no constraint and
    # the title shows full.
    remaining_after_id = max(inner_width - fixed_non_id_overhead - id_width - 1, 0)

    constrained? = natural_title_width + @max_latest_width > remaining_after_id

    title_cap =
      if constrained?, do: min(@title_constrained_cap, natural_title_width), else: natural_title_width

    title_target = min(title_cap, max(remaining_after_id - @min_latest_width, 0))
    title_width = max(min(title_target, remaining_after_id), 0)

    latest_width =
      min(@max_latest_width, max(remaining_after_id - title_width, @min_latest_width))

    %{
      id_width: id_width,
      age_width: age_width,
      title_width: title_width,
      latest_width: latest_width,
      show_progress?: show_progress?
    }
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

  defp pad_with_ansi(ansi, text, inner_width, right_border \\ "│") do
    # clip_and_pad fills to inner_width - 1 visual cols and then appends
    # `right_border` so every row carries a closing vertical bar on the
    # right side (matching the leading `│` on the left). Specific row
    # types pass `╮` / `╯` / `┤` for corner / divider variants.
    [
      ansi,
      clip_and_pad(text, max(inner_width - 1, 0)),
      right_border,
      @ansi_reset
    ]
  end

  defp padding_for(text, inner_width) do
    # Use visual_width, not String.length: emoji + CJK glyphs count as
    # one grapheme but render as TWO terminal columns. Padding by
    # grapheme count over-pads, the line exceeds inner_width, and the
    # terminal wraps — which throws off our line-count bookkeeping and
    # eventually scrolls the top of the pane off-screen.
    #
    # Reserve the last visual column for the right `│` border so each
    # metadata row closes cleanly. The iodata returned here ends with
    # the border glyph; callers don't need to append it themselves.
    visible = visual_width(strip_ansi(text))
    pad = String.duplicate(" ", max(inner_width - visible - 1, 0))
    [pad, @ansi_gray, "│", @ansi_reset]
  end

  # Visual column width of `text` in terminal cells. Wide-grapheme
  # detection follows the Unicode East-Asian-Width "Wide" + "Fullwidth"
  # ranges plus the emoji blocks (1F000+). Common multi-byte symbols
  # used in our chrome (·, →, …, box-drawing) intentionally score 1 so
  # padding lines up.
  defp visual_width(text) when is_binary(text) do
    text
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  defp grapheme_width(g) do
    case String.to_charlist(g) do
      [cp | _] -> codepoint_width(cp)
      [] -> 0
    end
  end

  # ASCII fast path.
  defp codepoint_width(cp) when cp < 0x80, do: 1
  # Zero-width: combining marks, ZWJ, variation selectors. Keep these
  # at 0 so emoji presentation modifiers don't double-count.
  defp codepoint_width(cp) when cp >= 0x300 and cp <= 0x36F, do: 0
  defp codepoint_width(0x200B), do: 0
  defp codepoint_width(0x200C), do: 0
  defp codepoint_width(0x200D), do: 0
  defp codepoint_width(0xFE0E), do: 0
  defp codepoint_width(0xFE0F), do: 0
  # East-Asian Wide + Fullwidth ranges.
  defp codepoint_width(cp) when cp >= 0x1100 and cp <= 0x115F, do: 2
  defp codepoint_width(cp) when cp >= 0x2E80 and cp <= 0x303E, do: 2
  defp codepoint_width(cp) when cp >= 0x3041 and cp <= 0x33FF, do: 2
  defp codepoint_width(cp) when cp >= 0x3400 and cp <= 0x4DBF, do: 2
  defp codepoint_width(cp) when cp >= 0x4E00 and cp <= 0x9FFF, do: 2
  defp codepoint_width(cp) when cp >= 0xA000 and cp <= 0xA4CF, do: 2
  defp codepoint_width(cp) when cp >= 0xAC00 and cp <= 0xD7A3, do: 2
  defp codepoint_width(cp) when cp >= 0xF900 and cp <= 0xFAFF, do: 2
  defp codepoint_width(cp) when cp >= 0xFE30 and cp <= 0xFE4F, do: 2
  defp codepoint_width(cp) when cp >= 0xFF00 and cp <= 0xFF60, do: 2
  defp codepoint_width(cp) when cp >= 0xFFE0 and cp <= 0xFFE6, do: 2
  # Selected symbol blocks that terminals render as wide / emoji-style.
  # Many cells in 2600-26FF are 1 col in some terminals but render as
  # 2 in modern emoji fonts — overcount is safer than wrap.
  defp codepoint_width(cp) when cp >= 0x2600 and cp <= 0x27BF, do: 2
  defp codepoint_width(cp) when cp >= 0x2B00 and cp <= 0x2BFF, do: 2
  defp codepoint_width(cp) when cp >= 0x1F000, do: 2
  # Everything else (Latin-1 supplement, arrows, box drawing, …) is 1.
  defp codepoint_width(_cp), do: 1

  # Truncate `text` to at most `limit` visual columns, splitting on
  # grapheme boundaries so a multi-codepoint emoji is never cut.
  defp truncate_visual(_text, limit) when limit <= 0, do: ""

  defp truncate_visual(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      w = grapheme_width(g)

      if used + w > limit do
        {:halt, {acc, used}}
      else
        {:cont, {acc <> g, used + w}}
      end
    end)
    |> elem(0)
  end

  # Pad a (raw, no-ansi) text to exactly `inner_width` visual columns,
  # truncating with `…` if the text would otherwise wrap. Caller is
  # responsible for any wrapping ANSI escapes.
  defp clip_and_pad(text, inner_width) do
    if visual_width(text) <= inner_width do
      [text, String.duplicate(" ", max(inner_width - visual_width(text), 0))]
    else
      trimmed = truncate_visual(text, max(inner_width - 1, 0)) <> "…"
      [trimmed, String.duplicate(" ", max(inner_width - visual_width(trimmed), 0))]
    end
  end

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

  # --- Debug perf footer ---------------------------------------------
  # When AIUR_DEBUG=1, the agent list shows a fixed 3-row footer with
  # the three milestones the user actually cares about:
  #   1. agent list ready       (boot -> agent_list rendered)
  #   2. chat pane visible      (Enter -> placeholder pane on screen)
  #   3. opencode render        (Enter -> opencode-attach painted convo)
  #
  # Each row shows the last measured value or `…` while we wait.

  defp debug_perf_footer(state, inner_width) do
    if Map.get(state, :debug_mode?, false) do
      summary = Map.get(state, :perf_summary, %{})

      [
        perf_compact_row(summary, inner_width),
        eol(),
        warmth_footer_row(state, inner_width),
        eol()
      ]
    else
      []
    end
  end

  defp debug_footer_line_count(state) do
    if Map.get(state, :debug_mode?, false), do: 2, else: 0
  end

  defp perf_compact_row(summary, inner_width) do
    text =
      "  perf  list " <>
        format_perf_ms(Map.get(summary, :agent_list_ready_ms)) <>
        " · pane " <>
        format_perf_ms(Map.get(summary, :chat_pane_visible_ms)) <>
        " · render " <> format_perf_ms(Map.get(summary, :opencode_render_ms))

    # Pad to inner_width - 1 to leave the autowrap-safety column;
    # no right border because this row sits below the bordered box.
    [IO.ANSI.faint(), clip_and_pad(text, max(inner_width - 1, 0)), IO.ANSI.reset()]
  end

  defp format_perf_ms(nil), do: "…"
  defp format_perf_ms(ms) when ms < 1_000, do: "#{ms}ms"

  defp format_perf_ms(ms),
    do: :io_lib.format("~.1fs", [ms / 1000]) |> IO.iodata_to_binary()

  defp warmth_footer_row(state, inner_width) do
    rows =
      state
      |> Map.get(:warmth_events, [])
      |> WarmthReport.from_events()

    summary = format_warmth_summary(rows)
    label = "  warmth (loose→strict): " <> summary
    [IO.ANSI.faint(), clip_and_pad(label, inner_width), IO.ANSI.reset()]
  end

  defp format_warmth_summary([]), do: "no attach events yet"

  defp format_warmth_summary(rows) do
    rows
    |> Enum.take(3)
    |> Enum.map_join("  ", fn r ->
      delta =
        case r.loose_to_strict_delta_ms do
          n when is_integer(n) -> "#{n}ms"
          :strict_never_reached -> "never"
          other -> Atom.to_string(other)
        end

      "#{r.identifier}=#{delta}"
    end)
  end

  # --- Debug events ticker ------------------------------------------------
  # When `--debug` is on, the bottom of the agent-list pane shows the
  # most recent event lifecycle marks. Three kinds, in three columns of
  # visual weight:
  #
  #   ✉️  publish — Aiur.Events.Publisher.publish/3 accepted the event
  #   📥  receive — Aiur.Events.SubscriptionStore enqueued the event
  #                  for a specific subscribing identifier
  #   📄  read    — the agent's queue consumed an `events_digest` item
  #                  (the digest reached the agent's prompt)
  #
  # The buffer is newest-first. Renderer trims to `budget` lines so
  # the ticker never overflows the pane height; older events are
  # silently dropped from the visible window.

  defp debug_events_ticker(state, inner_width, budget) do
    if Map.get(state, :debug_mode?, false) and budget > 0 do
      header_line = ticker_header_row(inner_width)
      # Header eats one row; remaining is the visible event capacity.
      capacity = max(budget - 1, 0)

      # state.debug_events is newest-first. Keep the newest `capacity`
      # (drop the oldest beyond that), then reverse so we render
      # oldest-at-top → newest-at-bottom. Events anchor to the BOTTOM
      # of the ticker section: when fewer than `capacity` exist, blank
      # padding fills the rows above so the newest event always sits
      # at the bottom of the pane.
      events =
        state
        |> Map.get(:debug_events, [])
        |> Enum.take(capacity)
        |> Enum.reverse()

      pad_count = max(capacity - length(events), 0)
      blank = ticker_blank_row(inner_width)
      blank_rows = List.duplicate([blank, eol()], pad_count)
      event_rows = Enum.flat_map(events, &[ticker_event_row(&1, inner_width), eol()])

      {[header_line, eol(), blank_rows, event_rows], 1 + pad_count + length(events)}
    else
      {[], 0}
    end
  end

  defp ticker_blank_row(inner_width) do
    String.duplicate(" ", inner_width)
  end

  defp ticker_header_row(inner_width) do
    # Two label variants: full and compact. Pick the widest that fits
    # so a narrow tmux split doesn't wrap the header.
    full = "  events (✉️ publish · 📥 receive · 📄 read)"
    compact = "  events  ✉️ 📥 📄"

    label =
      cond do
        visual_width(full) <= inner_width -> full
        visual_width(compact) <= inner_width -> compact
        true -> "  events"
      end

    [IO.ANSI.faint(), clip_and_pad(label, inner_width), IO.ANSI.reset()]
  end

  defp ticker_event_row(%{kind: kind, topic: topic} = entry, inner_width) do
    glyph =
      case kind do
        :publish -> "✉️"
        :receive -> "📥"
        :read -> "📄"
      end

    id_part =
      case Map.get(entry, :id) do
        n when is_integer(n) -> " id=#{n}"
        _ -> ""
      end

    identifier_part =
      case Map.get(entry, :identifier) do
        id when is_binary(id) and id != "" -> " (##{id})"
        _ -> ""
      end

    text = "  #{glyph} #{topic}#{id_part}#{identifier_part}"
    [IO.ANSI.faint(), clip_and_pad(text, inner_width), IO.ANSI.reset()]
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
