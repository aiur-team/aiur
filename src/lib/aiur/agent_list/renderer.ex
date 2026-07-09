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

  # Fixed-width remote-control indicator column, sat immediately right
  # of the identifier. Always allocated (even when no agent has RC on)
  # so columns never shift when an agent is handed off. 3 columns:
  # emoji (2 terminal columns) + trailing space.
  @rc_cell_width 3

  # Maximum width allotted to the Latest column. The column takes
  # remaining inner width up to this cap; if there's less room
  # available, the column shrinks (and the message truncates with `…`).
  @max_latest_width 60
  @min_latest_width 0

  # Fixed-width progress bar + ETA columns. Sized so they always
  # render regardless of terminal width (collapse Latest first).
  # Layout: `<bar 10> <eta 5>` = 10 + 1 + 5 = 16 cols. The bar
  # is 10 cells wide so each 10% step the agent emits maps to
  # exactly one filled cell on screen.
  @progress_bar_width 10
  @progress_cell_width @progress_bar_width

  # Runtime ticker: width 7 fits `h:MM:SS` for runs up to 9h59m59s.
  # Beyond that, format_runtime/1 rolls over to `Nh` so the column
  # still fits.
  @runtime_cell_width 7

  @min_id_width 4
  @min_title_width 6
  # When the terminal can't fit the full natural title + Latest at
  # @max_latest_width, cap the title at this many chars so other
  # columns aren't pushed off screen. With a wide enough terminal,
  # the constraint doesn't trigger and the title renders in full.
  @title_constrained_cap 25

  # Floor width for the MODEL column: holds the longest base name
  # ("Sonnet" = 6). The column reserves this much when shown and expands
  # to a model's full version string only into spare width (see
  # compute_layout/2). Like PROGRESS, the whole column drops at extreme
  # narrowness — but only after TITLE/LATEST are already at their minimums.
  @model_base_width 6

  # ANSI palette.
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_gray IO.ANSI.light_black()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_reverse IO.ANSI.reverse()
  # ANSI fallbacks for the per-model colors below, used when the terminal
  # has no 24-bit truecolor support (`:truecolor?` false).
  @ansi_magenta IO.ANSI.magenta()
  @ansi_blue IO.ANSI.blue()

  # Per-model text colors for the MODEL column, mirroring the website's
  # `.ag-opus` / `.ag-sonnet` / `.ag-codex` classes in
  # `website/src/styles.css`. Keep these hexes in sync with that file:
  #   opus   → #c69bff  (light theme #8a4fd0)
  #   sonnet → #59b0ff  (light theme #1f6fd6)
  #   codex  → #3fb950  (light theme #1f9d4d)
  # 24-bit escapes below match the dark-theme hexes exactly; terminals
  # without truecolor fall back to the nearest ANSI color (magenta/blue/
  # green). The light-theme hexes are recorded here for parity but the TUI
  # renders against an arbitrary terminal background, so it uses the
  # dark-theme values as the canonical mapping.
  @model_truecolor %{opus: "\e[38;2;198;155;255m", sonnet: "\e[38;2;89;176;255m", codex: "\e[38;2;63;185;80m"}
  @model_ansi %{opus: @ansi_magenta, sonnet: @ansi_blue, codex: @ansi_green}

  # Work states meaning the agent has finished this iteration. Used to
  # render 🏁 and to suppress the warming/starting LATEST placeholder so
  # a finished agent never freezes on "Warming up…" (#425). Named
  # "finished" rather than "terminal" because this module already uses
  # "terminal" for the TTY.
  @finished_work_states [:deactivated, "deactivated", :done, "done"]

  # Work states the renderer paints with `AgentEvents.state_emoji/1`
  # (each has a canonical glyph) rather than the warm-marker progression
  # (⏳ → 🔘 → ⚪ → 🟢). Superset of @finished_work_states plus the
  # still-alive paused/error/sleeping states (`:sleeping` → 💤, #418) —
  # derived from @finished_work_states so a future finished state lands
  # in both sets at once.
  @state_emoji_work_states [
                             :paused,
                             "paused",
                             :error,
                             "error",
                             :sleeping,
                             "sleeping"
                           ] ++ @finished_work_states

  # Faint dotted track shown in the PROGRESS column when an agent has no
  # samples yet. A full row of `░` (the bar's empty-cell glyph) reads as
  # a corrupt/half-filled bar (#425); the dotted track reads
  # unambiguously as "no progress data yet" while keeping the fixed
  # @progress_bar_width.
  @empty_progress_track String.duplicate("·", @progress_bar_width)

  @type state :: %{
          required(:summaries) => [AgentEvents.agent_summary()],
          required(:selection_index) => non_neg_integer(),
          optional(:selection_focus) => :agents | :max_agents,
          required(:columns) => pos_integer(),
          required(:rows) => pos_integer(),
          required(:project_label) => String.t() | nil,
          required(:dashboard_url) => String.t() | nil
        }

  @spec render(state()) :: iodata()
  def render(state) when is_map(state) do
    cols = Map.get(state, :columns, 80)
    rows = Map.get(state, :rows, 24)
    inner_width = max(cols - 1, 1)

    if Map.get(state, :help_visible?, false) do
      render_help(inner_width, rows)
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
        |> Map.put(:progress_by_id, Map.get(state, :progress_by_id, %{}))
        |> Map.put(:phase_by_identifier, Map.get(state, :phase_by_identifier, %{}))
        |> Map.put(:now_ms, Map.get(state, :now_ms, System.monotonic_time(:millisecond)))
        |> Map.put(:prewarm_active?, Map.get(state, :prewarm_active?, false))
        |> Map.put(:prewarm_phase, Map.get(state, :prewarm_phase))
        |> Map.put(:project_label, Map.get(state, :project_label))
        |> Map.put(:truecolor?, Map.get(state, :truecolor?, true))

      markers = compute_markers(state, summaries)

      # Footer: keybinds below the box. When width is tight, `v layout`
      # wraps to its own row. An optional RC line (session URL or
      # transient hint) rides above the keybinds.
      footer_render = footer_split(inner_width, rc_footer_text(state))
      footer_lines = footer_render.line_count

      base_lines = lines_emitted(state, inner_width, footer_lines)

      # Reserve at least one row of breathing room before the bottom of
      # the pane so the events block never overflows tmux's scroll
      # region. Events are inside the AgentList box now, separated by
      # a horizontal divider when present. When the budget is too tight
      # the events block collapses to zero rows automatically.
      events_budget = max(rows - base_lines - 1, 0)
      {events_iodata, events_line_count} = events_block(state, inner_width, events_budget)

      [
        # Begin synchronized update (DEC 2026): the terminal buffers the
        # whole frame and paints it atomically at the matching `?2026l`.
        # Without it, a slow consumer can render a PARTIAL frame — and a
        # multi-byte glyph (emoji, OSC 8 link, box drawing) split across
        # the partial boundary momentarily paints as `?` replacement
        # characters in the divider/events region during busy redraws
        # (the "??????" flicker). Terminals without 2026 support ignore
        # the sequence; tmux >= 3.4 passes it through.
        "\e[?2026h",
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
        title_row(inner_width),
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
        events_iodata,
        bottom_border(inner_width),
        eol(),
        footer_render.iodata,
        clear_remaining(rows, base_lines + events_line_count),
        # Re-emit hide + no-blink + park-home AFTER all painting,
        # so any tmux refresh, focus change, or sibling process
        # that flipped the cursor back on gets countered on every
        # render tick. Multiple consecutive emits are no-ops; the
        # cost is six bytes per tick.
        "\e[?25l",
        "\e[?12l",
        "\e[H",
        # End synchronized update — the frame paints atomically here.
        "\e[?2026l"
      ]
    end
  end

  # Help overlay reusing the same bordered chrome as the main view.
  # Lists the keybinds and the state-circle legend so an operator new
  # to the agent-list pane can self-orient.
  defp render_help(inner_width, rows) do
    body_rows = help_body_rows(inner_width)
    body_count = length(body_rows)

    drawn =
      [
        "\e[H",
        title_row(inner_width),
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
         "🧠  brainstorming",
         "📋  planning",
         "🔨  implementing",
         "🔍  reviewing",
         "🟢  working — pane open now (no active phase)",
         "⏸️  agent paused",
         "🔴  agent in error state",
         "🏁  awaiting human review — space or chat to reactivate",
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

  defp title_row(inner_width) do
    title = "╭─ AIUR"
    title_visual = visual_width(title)

    # `╮` rounded corner reserved at the far right; padding fills the gap
    # between the AIUR title and the corner.
    pad_count = max(inner_width - title_visual - 1, 1)
    pad = String.duplicate(" ", pad_count)

    [@ansi_bold, title, @ansi_reset, pad, @ansi_gray, "╮", @ansi_reset]
  end

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

  defp project_row(nil, inner_width),
    do: metadata_row_iolist("Project:", "n/a", @ansi_gray, inner_width)

  defp project_row("", inner_width),
    do: metadata_row_iolist("Project:", "n/a", @ansi_gray, inner_width)

  defp project_row(label, inner_width),
    do: metadata_row_iolist("Project:", label, @ansi_cyan, inner_width)

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
    drain_text = if count > max, do: " drain", else: ""
    plain = "#{prefix}#{label} #{kind} (#{count}/#{max_text}#{drain_text})#{affordance}"
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
      drain_text,
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
    # Inject a "newest" label at the far-left of the bottom border so
    # the operator can read the timeline direction in the events log:
    #   `╰─ newest ──...──╯`
    # The label sits between the `╰` corner and the trailing fill. When
    # the box is too narrow (`< 14` cols) for label + chrome, fall back
    # to the plain border so we never truncate the corner glyphs.
    label_text = "newest"
    label_visual = String.length(label_text)
    # ╰ + ─ + space + label + space + 1 trailing ─ minimum + ╯ = label_visual + 5
    min_for_label = label_visual + 6

    if inner_width >= min_for_label do
      trailing_fill = String.duplicate("─", max(inner_width - label_visual - 5, 0))

      [
        @ansi_gray,
        "╰─ ",
        @ansi_reset,
        @ansi_gray,
        IO.ANSI.italic(),
        label_text,
        @ansi_reset,
        @ansi_gray,
        " ",
        trailing_fill,
        "╯",
        @ansi_reset
      ]
    else
      [
        pad_with_ansi(
          @ansi_gray,
          "╰" <> String.duplicate("─", max(inner_width - 2, 0)),
          inner_width,
          "╯"
        )
      ]
    end
  end

  # Footer keybinds. `v layout` rides on the full row when there's
  # room, otherwise wraps to a second row so we don't truncate the more
  # frequently used keybinds (select/open/pause/remote/help/quit).
  @keybinds_full "↑/↓ select   enter open   space pause/resume   r remote   v layout   ? help   q quit"
  @keybinds_primary "↑/↓ select   enter open   space pause/resume   r remote   ? help   q quit"
  @keybinds_secondary "v layout"
  @footer_left_padding 2
  @footer_left_padding_str "  "

  # Bottom rows: keybinds rendered BELOW the bordered AgentList box (no
  # right `│` wall). The cascade prefers fewer rows when width permits.
  #
  # - 1 row: full keybinds fit
  # - 2 rows: primary keybinds, "v layout" below (narrow)
  defp footer_split(inner_width, rc_line) do
    base = footer_keybinds_split(inner_width)

    case rc_line do
      text when is_binary(text) and text != "" ->
        rc_row = [
          left_only_row(
            truncate(text, max(inner_width - @footer_left_padding - 1, 0)),
            inner_width
          ),
          eol()
        ]

        %{iodata: [rc_row | base.iodata], line_count: base.line_count + 1}

      _ ->
        base
    end
  end

  defp footer_keybinds_split(inner_width) do
    if visual_width(@footer_left_padding_str <> @keybinds_full) + 1 <= inner_width do
      %{iodata: [left_only_row(@keybinds_full, inner_width), eol()], line_count: 1}
    else
      %{
        iodata: [
          left_only_row(@keybinds_primary, inner_width),
          eol(),
          left_only_row(@keybinds_secondary, inner_width),
          eol()
        ],
        line_count: 2
      }
    end
  end

  # RC footer text: just the transient hint (immediate feedback after the
  # `r`/Space toggle). The session URL itself now rides in the agent's
  # chat-pane top border (set via tmux in `Aiur.AgentList.App`) so it
  # travels with the pane it belongs to instead of floating in the footer.
  defp rc_footer_text(state) do
    case Map.get(state, :remote_control_hint) do
      hint when is_binary(hint) and hint != "" -> hint
      _ -> nil
    end
  end

  defp left_only_row(text, inner_width) do
    body = String.duplicate(" ", @footer_left_padding) <> text
    pad_with_ansi(@ansi_dim, body, inner_width, " ")
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width, layout) do
    progress_header =
      if layout.show_progress?, do: [" ", cell("PROGRESS", @progress_cell_width)], else: []

    runtime_header = [" ", cell("TIME", @runtime_cell_width)]

    model_header =
      if layout.model_width > 0, do: [cell("MODEL", layout.model_width), " "], else: []

    body = [
      "│   ",
      cell("ID", layout.id_width),
      cell("", @rc_cell_width),
      cell("", @state_cell_width),
      cell("", @attention_cell_width),
      model_header,
      cell("TITLE", layout.title_width),
      " ",
      cell("LATEST", layout.latest_width),
      progress_header,
      runtime_header
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

  defp render_rows([], _idx, _selection_focus, inner_width, layout, _markers) do
    [
      pad_with_ansi(@ansi_dim, "│   " <> empty_body_text(layout), inner_width),
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

  # Before any agent populates the list, show a pre-warm loading line (spinner +
  # the live phase) while the shared base builds; otherwise the usual empty hint.
  # Once summaries are non-empty this branch isn't reached, so a populated list
  # always wins over a stale active flag.
  defp empty_body_text(layout) do
    if Map.get(layout, :prewarm_active?, false) do
      spinner_frame(layout) <> " Pre-warming base (" <> prewarm_label(Map.get(layout, :prewarm_phase)) <> ")…"
    else
      "(no agents running)"
    end
  end

  defp prewarm_label(:cloning), do: "cloning"
  defp prewarm_label(:fetching), do: "fetching main"
  defp prewarm_label(:building), do: "compiling"
  defp prewarm_label(_phase), do: "warming up"

  defp render_row(summary, selected?, inner_width, layout, markers) do
    marker = if selected?, do: "▶ ", else: "  "
    id_str = to_string(Map.get(summary, :identifier) || "")
    title = Map.get(summary, :title) || ""

    id_cell = id_cell_with_link(id_str, layout)
    phase = Map.get(Map.get(layout, :phase_by_identifier, %{}), id_str)
    state_cell = emoji_cell(summary_emoji(summary, markers, phase), @state_cell_width)
    attention_cell = attention_cell(id_str, layout)
    title_cell = cell(title, layout.title_width)
    latest_cell = latest_cell(id_str, layout, summary)
    model_block = model_cell_block(summary, layout)

    progress_block =
      if layout.show_progress? do
        [" ", @ansi_dim, progress_cell(id_str, layout), @ansi_reset]
      else
        []
      end

    runtime_block = [" ", @ansi_dim, runtime_cell(summary), @ansi_reset]

    body = [
      "│ ",
      marker,
      @ansi_cyan,
      id_cell,
      @ansi_reset,
      rc_cell(summary),
      state_cell,
      attention_cell,
      model_block,
      title_cell,
      " ",
      @ansi_dim,
      latest_cell,
      @ansi_reset,
      progress_block,
      runtime_block
    ]

    progress_width = if layout.show_progress?, do: @progress_cell_width + 1, else: 0
    runtime_width = @runtime_cell_width + 1
    model_width = if layout.model_width > 0, do: layout.model_width + 1, else: 0

    # Visual columns consumed by the body, in order:
    #   `│ ` (2) + marker (2) + id_cell + rc_cell (3)
    #   + state_cell (3) + attention_cell (4) + model_block + title_cell
    #   + ` ` (1) + latest_cell + progress_block + runtime_block.
    # Sum the parts directly so the right `│` border lands at the
    # same column as the metadata/separator rows above.
    plain_visual =
      2 + 2 + layout.id_width + @rc_cell_width + @state_cell_width + @attention_cell_width +
        model_width + layout.title_width + 1 + layout.latest_width + progress_width +
        runtime_width

    # Reserve the last column for the right `│` border so each row
    # closes cleanly. Pad to (inner_width - 1) then append the bar.
    pad = String.duplicate(" ", max(inner_width - 1 - plain_visual, 0))
    row = [body, pad]

    if selected? do
      # Highlight the selected row with the terminal `reverse`/standout
      # attribute rather than a fixed background color, so the row stays
      # legible on both dark and light terminal themes (#366). Interior
      # color SGRs are stripped first: under `reverse` a foreground color
      # would invert into a background block and fragment the highlight,
      # so the whole row inverts uniformly instead. OSC 8 ticket
      # hyperlinks survive (strip_csi/1 leaves them intact). The closing
      # `│` border stays un-inverted, matching the unselected rows.
      highlighted =
        row
        |> IO.iodata_to_binary()
        |> strip_csi()

      [@ansi_reverse, highlighted, @ansi_reset, @ansi_gray, "│", @ansi_reset]
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

  # Remote-control indicator cell. `:launching` shows 📲 (registration
  # is a network round-trip, so the operator gets feedback the instant
  # `r` is pressed, before the URL lands — a distinct glyph from the ⏳
  # warming marker so the two never read as the same state); `:on`
  # shows 📱; `:failed` shows ❌; `:off`/absent shows nothing. Width is
  # fixed at @rc_cell_width regardless so column alignment never shifts.
  defp rc_cell(summary) do
    glyph =
      case Map.get(summary, :remote_control) do
        %{status: :launching} -> "📲"
        %{status: :on} -> "📱"
        %{status: :failed} -> "❌"
        _ -> ""
      end

    emoji_cell(glyph, @rc_cell_width)
  end

  # Progress + ETA pair, rendered as one cell of fixed width 16:
  # `<bar 10> <eta 5>`. When the tracker has no samples for the id we
  # render the faint dotted @empty_progress_track (not a full row of
  # `░`, which reads as a corrupt/half-filled bar — #425). Width stays
  # the same either way so the column never jitters.
  #
  # At percent: 100 (the agent's stop-work signal — see
  # `src/prompts/shared-agent-instructions.md`'s "Progress emits"
  # section), the bar is tinted green so the operator sees at a
  # glance that the agent is done for this iteration. The cell is
  # otherwise wrapped in `@ansi_dim` at the call site; we reset and
  # re-apply dim around the green wrap so terminals render the
  # color cleanly.
  defp progress_cell(id, layout) do
    samples = layout |> Map.get(:progress_by_id, %{}) |> Map.get(id, [])
    now_ms = Map.get(layout, :now_ms, System.monotonic_time(:millisecond))

    case ProgressTracker.estimate(samples, now_ms) do
      :unknown ->
        @empty_progress_track

      %{percent: 100} ->
        full_bar = ProgressTracker.bar(100, @progress_bar_width)
        @ansi_reset <> @ansi_green <> full_bar <> @ansi_reset <> @ansi_dim

      %{percent: pct} ->
        ProgressTracker.bar(pct, @progress_bar_width)
    end
  end

  # Cumulative wall-clock the agent has been running. Always-on; ticks
  # up every render. Source: `summary.runtime_seconds`, already kept
  # current by AgentList.App on every poll. Format chosen so the
  # column never widens:
  #   * <60s   → `0:01` … `0:59`
  #   * <60m   → `1:23` … `59:59`
  #   * <10h   → `1:02:03` (h:MM:SS — fits @runtime_cell_width 7)
  #   * ≥10h   → `Nh` short form (rare; stays inside the cell)
  defp runtime_cell(summary) do
    seconds = Map.get(summary, :runtime_seconds) || 0
    cell(format_runtime(seconds), @runtime_cell_width)
  end

  defp format_runtime(seconds) when is_integer(seconds) and seconds < 0, do: "0:00"

  defp format_runtime(seconds) when is_integer(seconds) and seconds < 3600 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}:#{pad2(secs)}"
  end

  defp format_runtime(seconds) when is_integer(seconds) and seconds < 36_000 do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    "#{hours}:#{pad2(mins)}:#{pad2(secs)}"
  end

  defp format_runtime(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"

  defp format_runtime(_), do: "0:00"

  defp pad2(n) when is_integer(n) and n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

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
        # A finished (deactivated/done) agent has released its slot, so
        # `attach` is nil — but it is NOT warming up. Suppress the
        # warming/starting placeholder so the row doesn't freeze on
        # "Warming up…" after the agent has gone terminal (#425).
        Map.get(summary, :work_state) in @finished_work_states -> ""
        Map.get(summary, :status) == :queued -> "Queueing agent…"
        is_nil(attach) -> "Warming up…"
        match?(%{visible_in: nil}, attach) -> "Warming up…"
        not has_content -> starting_phrase(summary)
        true -> ""
      end

    if phrase == "", do: "", else: spinner <> " " <> phrase
  end

  # The "Starting" placeholder should name the agent's own engine, not a
  # hardcoded backend. The summary carries the resolved backend string
  # (e.g. "claude-repl", "codex"); the engine family is its first segment.
  defp starting_phrase(summary) do
    case engine_word(summary) do
      nil -> "Starting…"
      word -> "Starting #{word}…"
    end
  end

  defp engine_word(summary) do
    case Map.get(summary, :backend) do
      backend when is_binary(backend) -> backend |> String.split("-") |> List.first()
      _ -> nil
    end
  end

  # ---------- model column ---------------------------------------------------

  # Iodata for the MODEL column cell: per-model color + base-or-version text
  # + reset + the trailing separator space. `[]` when the column is dropped
  # (model_width 0). The version suffix shows only when the column has been
  # expanded into spare width (model_width > the base floor); otherwise the
  # base name is the floor. Queued / backend-less rows render a dim `–`.
  defp model_cell_block(summary, layout) do
    width = layout.model_width

    if width <= 0 do
      []
    else
      family = model_family(summary)
      text = model_text(summary, family, width)
      padded = cell(text, width)

      case model_color(family, Map.get(layout, :truecolor?, true)) do
        # Families with no website color: dim the queued/unknown `–`
        # placeholder (family nil); leave a generic claude/haiku name in the
        # default foreground.
        nil when is_nil(family) -> [@ansi_dim, padded, @ansi_reset, " "]
        nil -> [padded, " "]
        color -> [color, padded, @ansi_reset, " "]
      end
    end
  end

  # Display text for one row's model cell at the resolved column width. Base
  # name is the floor; when the column is wide enough to have been expanded
  # (width past the base floor) the full version string is preferred, falling
  # back to the base name for unpinned models. A row with no resolvable model
  # (queued / no backend) shows a dim en-dash placeholder.
  defp model_text(summary, family, width) do
    case model_base(family) do
      "" ->
        "–"

      base ->
        if width > @model_base_width do
          model_full_name(family, Map.get(summary, :model)) || base
        else
          base
        end
    end
  end

  # Natural full width a row wants in the MODEL column: the full version
  # string when a model is pinned, else the base name's length (0 when the
  # row has no resolvable model). compute_layout/2 takes the max across rows.
  defp model_natural_width(summary) do
    family = model_family(summary)

    case model_full_name(family, Map.get(summary, :model)) do
      nil -> String.length(model_base(family))
      full -> String.length(full)
    end
  end

  # Website model family driving color + base name. The pinned variant is the
  # most specific signal (opus/sonnet/haiku for claude, gpt for codex); when
  # absent we fall back to the backend family (`codex`, or a generic `claude`
  # with no opus/sonnet pin). `nil` for queued / backend-less rows.
  defp model_family(summary) do
    case Map.get(summary, :model) do
      "opus" <> _ -> :opus
      "sonnet" <> _ -> :sonnet
      "haiku" <> _ -> :haiku
      "gpt" <> _ -> :codex
      _ -> family_from_backend(summary)
    end
  end

  defp family_from_backend(summary) do
    case engine_word(summary) do
      "codex" -> :codex
      "claude" -> :claude
      _ -> nil
    end
  end

  defp model_base(:opus), do: "Opus"
  defp model_base(:sonnet), do: "Sonnet"
  defp model_base(:haiku), do: "Haiku"
  defp model_base(:codex), do: "Codex"
  defp model_base(:claude), do: "Claude"
  defp model_base(_), do: ""

  # Full human-readable version string, or nil when no version is pinned.
  #   {:opus, "opus-4-8"}    -> "Claude Opus 4.8"
  #   {:sonnet, "sonnet-4-6"}-> "Claude Sonnet 4.6"
  #   {:codex, "gpt-5.5"}    -> "Codex GPT-5.5"
  defp model_full_name(:codex, model) when is_binary(model) do
    "Codex " <> String.replace_prefix(model, "gpt", "GPT")
  end

  defp model_full_name(family, model) when family in [:opus, :sonnet, :haiku] and is_binary(model) do
    case String.split(model, "-", parts: 2) do
      [_family] -> "Claude " <> model_base(family)
      [_family, version] -> "Claude " <> model_base(family) <> " " <> String.replace(version, "-", ".")
    end
  end

  defp model_full_name(_family, _model), do: nil

  # 24-bit truecolor escape (preferred) or nearest ANSI fallback for a
  # model family. `nil` for families with no website color (haiku, generic
  # claude, queued) — those render uncolored.
  defp model_color(family, true), do: Map.get(@model_truecolor, family)
  defp model_color(family, _falsey), do: Map.get(@model_ansi, family)

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

  # `summary_emoji` shows, for a running working agent, the active
  # workflow phase (🧠/📋/🔨/🔍 — #68) when one is known, falling back
  # to the precomputed instant-open marker otherwise. Pre-warm ⏳ still
  # wins while the pane isn't warm. Paused/error/done/deactivated defer
  # to AgentEvents.
  defp summary_emoji(%{status: :queued}, _markers, _phase), do: "⚫"

  defp summary_emoji(%{status: :running, identifier: identifier} = summary, markers, phase) do
    case Map.get(summary, :work_state) do
      state when state in @state_emoji_work_states ->
        # `:deactivated` (and `:done`) are terminal: route through
        # AgentEvents.state_emoji so a finished agent reaches 🏁 instead
        # of falling through to the warm-marker logic and freezing on ⏳
        # (#425). emoji_sort_key and the progress seeding already treat
        # these as finished; the renderer was the lone surface out of
        # sync. `:sleeping` is still-alive but also routes through
        # AgentEvents.state_emoji for its 💤 glyph (#418).
        AgentEvents.state_emoji(state)

      _ ->
        marker = Map.get(markers, to_string(identifier), "⏳")

        if marker == "⏳" do
          "⏳"
        else
          phase_emoji(phase) || marker
        end
    end
  end

  defp summary_emoji(%{work_state: work_state}, _markers, _phase),
    do: AgentEvents.state_emoji(work_state)

  defp summary_emoji(_, _markers, _phase), do: "⚫"

  defp phase_emoji(:brainstorm), do: "🧠"
  defp phase_emoji(:plan), do: "📋"
  # U+1F528 hammer, not the U+1F6E0+FE0F hammer-and-wrench: the latter
  # needs a variation selector to get emoji presentation, and terminals
  # that default it to text presentation (e.g. Termius on iOS) render it
  # one column wide, breaking the fixed-width column math here. The plain
  # hammer has default emoji presentation, so it stays two columns.
  defp phase_emoji(:work), do: "🔨"
  defp phase_emoji(:review), do: "🔍"
  defp phase_emoji(_), do: nil

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

  # Compute per-frame column widths so identifiers only take as much
  # space as they actually need, leaving the rest for the title.
  # Recomputed on every render so a wider pane reflows immediately
  # when tmux resizes.
  defp compute_layout(summaries, inner_width) do
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

    # Widest full model string across the rows (e.g. "Claude Sonnet 4.6"),
    # floored at the base-name width. Drives the opportunistic expansion
    # below; a list with no pinned models stays at the floor.
    natural_model_width =
      summaries
      |> Enum.map(&model_natural_width/1)
      |> Enum.max(fn -> 0 end)
      |> max(@model_base_width)

    # `│ ` (2) + marker (2) + id + rc (3) + state (3)
    # + attention (4) + [model block] + title + ` ` (1) + [progress block]
    # + runtime_block (8) + ` │` (1 for the right border the row
    # closes with).
    runtime_block_width = @runtime_cell_width + 1

    base_overhead =
      2 + 2 + @rc_cell_width + @state_cell_width + @attention_cell_width + 1 + runtime_block_width

    show_progress? =
      inner_width - base_overhead - @min_id_width - @min_title_width - 1 >=
        @progress_cell_width + 1

    progress_block_width = if show_progress?, do: @progress_cell_width + 1, else: 0

    # The MODEL base column reserves @model_base_width (+ a separator),
    # mirroring the PROGRESS drop pattern: it shows only when there's room
    # for it beyond the id/title/latest minimums, so at extreme narrowness it
    # drops *after* TITLE/LATEST are already at their minimums — never before.
    show_model? =
      inner_width - base_overhead - progress_block_width - @min_id_width - @min_title_width -
        @min_latest_width - 1 >= @model_base_width + 1

    model_base_block = if show_model?, do: @model_base_width + 1, else: 0
    fixed_non_id_overhead = base_overhead + progress_block_width + model_base_block

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
      if constrained?,
        do: min(@title_constrained_cap, natural_title_width),
        else: natural_title_width

    title_target = min(title_cap, max(remaining_after_id - @min_latest_width, 0))
    title_width = max(min(title_target, remaining_after_id), 0)

    latest_width =
      min(@max_latest_width, max(remaining_after_id - title_width, @min_latest_width))

    # Whatever's left after TITLE and LATEST have taken their (capped) widths
    # is trailing pad. The version suffix is purely opportunistic: it expands
    # the MODEL column into that pad only when LATEST has hit its @max cap and
    # TITLE its natural width with room to spare — so it never shrinks either.
    # All-or-nothing to avoid mid-version truncation.
    leftover = remaining_after_id - title_width - latest_width

    model_width =
      cond do
        not show_model? -> 0
        leftover >= natural_model_width - @model_base_width -> natural_model_width
        true -> @model_base_width
      end

    %{
      id_width: id_width,
      title_width: title_width,
      latest_width: latest_width,
      model_width: model_width,
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

  @csi_re ~r/^\e\[[0-9;?]*[A-Za-z]/
  # Matches both OSC 8 forms (open carries a URL, close has an empty URL),
  # terminated by ST (`\e\\`) or BEL (`\a`).
  @osc8_re ~r/^\e\]8;;[^\e\a]*(?:\e\\|\a)/
  @osc8_close_re ~r/^\e\]8;;(?:\e\\|\a)/

  # Truncate `text` to at most `limit` visual columns, splitting on
  # grapheme boundaries so a multi-codepoint emoji is never cut. ANSI CSI
  # runs and OSC 8 hyperlink wrappers pass through at zero width and are
  # never split — counting their bytes against the budget would cut inside
  # an escape sequence, and the terminal then swallows the broken run,
  # hiding the whole line. If truncation lands inside an open hyperlink,
  # the link is closed so the trailing ellipsis renders outside it.
  defp truncate_visual(_text, limit) when limit <= 0, do: ""

  defp truncate_visual(text, limit) do
    {acc, _used, open_link?} = take_visible(text, limit, [], 0, false)
    result = IO.iodata_to_binary(acc)
    if open_link?, do: result <> "\e]8;;\e\\", else: result
  end

  defp take_visible("", _limit, acc, used, open?), do: {acc, used, open?}

  defp take_visible(text, limit, acc, used, open?) do
    case split_escape(text) do
      {:osc_close, seq, rest} -> take_visible(rest, limit, [acc, seq], used, false)
      {:osc_open, seq, rest} -> take_visible(rest, limit, [acc, seq], used, true)
      {:csi, seq, rest} -> take_visible(rest, limit, [acc, seq], used, open?)
      :none -> take_grapheme(text, limit, acc, used, open?)
    end
  end

  defp take_grapheme(text, limit, acc, used, open?) do
    {g, rest} = String.next_grapheme(text)
    w = grapheme_width(g)

    if used + w > limit do
      {acc, used, open?}
    else
      take_visible(rest, limit, [acc, g], used + w, open?)
    end
  end

  # Peel a leading ANSI/OSC escape sequence off `text`, returning its kind,
  # the sequence, and the remainder — or `:none` when `text` starts with a
  # visible grapheme.
  defp split_escape(text) do
    case Regex.run(@osc8_re, text, return: :binary) do
      [seq | _] -> {osc_kind(seq), seq, drop_prefix(text, seq)}
      nil -> split_csi(text)
    end
  end

  defp split_csi(text) do
    case Regex.run(@csi_re, text, return: :binary) do
      [seq | _] -> {:csi, seq, drop_prefix(text, seq)}
      nil -> :none
    end
  end

  defp osc_kind(seq) do
    if Regex.match?(@osc8_close_re, seq), do: :osc_close, else: :osc_open
  end

  defp drop_prefix(text, prefix) do
    plen = byte_size(prefix)
    binary_part(text, plen, byte_size(text) - plen)
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

  # Strip CSI sequences (colors, cursor moves) while leaving OSC 8
  # hyperlink wrappers intact. Used to flatten a row's interior colors
  # before wrapping it in the selected-row `reverse` highlight, without
  # dropping the clickable ticket link.
  defp strip_csi(text) do
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, text, "")
  end

  defp strip_ansi(text) do
    text
    # CSI (color/cursor) sequences: `\e[...m`, `\e[2J`, etc.
    |> strip_csi()
    # OSC 8 hyperlinks: `\e]8;;<url>\e\\<text>\e]8;;\e\\` (or BEL-terminated).
    # The text between the brackets is the visible part — we keep
    # everything between the ST and the closing OSC.
    |> then(&Regex.replace(~r/\e\]8;;[^\e\a]*(\e\\|\a)/, &1, ""))
  end

  defp eol, do: ["\e[K", "\r\n"]

  # Approximate count of rows the frame will draw (used for "blank the
  # rest" below the last rendered row so old content doesn't linger
  # when the agent list shrinks). Fixed rows: title, agents, project,
  # dashboard, separator, table header, table separator, bottom border
  # = 8. Footer is 1 or 2 rows depending on width. Body rows come
  # straight from state.summaries since `Aiur.AgentList.App` now
  # pre-filters the list before passing it in.
  defp lines_emitted(state, _inner_width, footer_lines) do
    summaries = Map.get(state, :summaries, [])
    body_rows = if summaries == [], do: 1, else: length(summaries)
    8 + footer_lines + body_rows
  end

  # --- Debug perf footer ---------------------------------------------
  # When AIUR_DEBUG=1, the agent list shows a fixed 3-row footer with
  # the three milestones the user actually cares about:
  #   1. agent list ready       (boot -> agent_list rendered)
  #   2. chat pane visible      (Enter -> placeholder pane on screen)
  #   3. opencode render        (Enter -> opencode-attach painted convo)
  #
  # Each row shows the last measured value or `…` while we wait.

  # --- Events block (inside the AgentList box) ---------------------------
  # The events block renders INSIDE the AgentList box, separated from the
  # agent rows by a `├──...──┤` divider when there are events to show.
  # Three kinds:
  #
  #   💬  publish — `Aiur.Events.Publisher.publish/3` accepted the event
  #   📬  receive — `Aiur.Events.SubscriptionStore` delivered the event
  #                  to a subscribing ticket
  #   📄  read    — the agent's queue consumed an `events_digest` item
  #                  (the digest reached the agent's prompt)
  #
  # Line format:
  #   `💬 99 Agent: "<message>"` (publish — source ticket is the agent)
  #   `📬 100 Agent received from 99: "<message>"` (cross-ticket receive)
  #   `📄 100 Agent ingested:` (read — minimal context)
  #
  # The table takes precedence for space: when `budget` is too small for
  # the divider + a single event row, the block collapses to nothing.

  defp events_block(state, inner_width, budget) do
    events = state |> Map.get(:debug_events, []) |> Enum.reject(&is_nil/1)

    cond do
      budget < 2 -> {[], 0}
      inner_width < 4 -> {[], 0}
      true -> render_events_block(state, events, inner_width, budget)
    end
  end

  defp render_events_block(state, events, inner_width, budget) do
    # Divider eats 1 row; remaining budget is the event capacity.
    # The block ALWAYS uses the full budget — when there are fewer
    # events than rows, empty `│ ... │` rows pad ABOVE the events so
    # the newest line sits flush with the bottom border (chat-log
    # layout: new at bottom, old scrolls up).
    capacity = max(budget - 1, 0)
    rendering_identifier = selected_identifier(state)
    repo = repo_identity(state)

    # state.debug_events is newest-first. Format each entry, drop the
    # ones the formatter suppresses (self-echoes), then take the newest
    # `capacity` so suppressed entries don't eat the budget.
    visible_lines =
      events
      |> Stream.map(&format_event_line(&1, rendering_identifier, repo))
      |> Stream.reject(&is_nil/1)
      |> Enum.take(capacity)
      |> Enum.reverse()

    deficit = max(capacity - length(visible_lines), 0)
    empty_rows = for _ <- 1..deficit//1, do: [empty_event_row(inner_width), eol()]

    event_rows =
      Enum.flat_map(visible_lines, &[event_box_inner_row(&1, inner_width), eol()])

    iodata = [
      events_divider_row(inner_width),
      eol(),
      empty_rows,
      event_rows
    ]

    {iodata, 1 + capacity}
  end

  defp selected_identifier(%{selection_index: idx, summaries: summaries})
       when is_list(summaries) do
    case Enum.at(summaries, idx) do
      %{identifier: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp selected_identifier(_state), do: nil

  defp events_divider_row(inner_width) do
    # Inject an "oldest" label at the far-right of the divider so the
    # operator can read the timeline direction:
    #   `├──...── oldest ─┤`
    # When the box is too narrow (`< 14` cols) for label + chrome, fall
    # back to the plain divider so we never truncate the corner glyphs.
    label_text = "oldest"
    label_visual = String.length(label_text)
    min_for_label = label_visual + 6

    if inner_width >= min_for_label do
      leading_fill = String.duplicate("─", max(inner_width - label_visual - 5, 0))

      [
        @ansi_gray,
        "├",
        leading_fill,
        " ",
        @ansi_reset,
        @ansi_gray,
        IO.ANSI.italic(),
        label_text,
        @ansi_reset,
        @ansi_gray,
        " ─┤",
        @ansi_reset
      ]
    else
      fill = String.duplicate("─", max(inner_width - 2, 0))
      [@ansi_gray, "├", fill, "┤", @ansi_reset]
    end
  end

  # `│ <text padded> │` — the `│ ` + ` │` chrome eats 4 visual columns.
  defp event_box_inner_row(text, inner_width) do
    body_width = max(inner_width - 4, 0)
    padded = clip_and_pad(text, body_width)
    [IO.ANSI.faint(), "│ ", padded, " │", IO.ANSI.reset()]
  end

  # Empty `│       │` row used to pad the events block up to its full
  # budget when there are fewer events than rows available.
  defp empty_event_row(inner_width) do
    fill = String.duplicate(" ", max(inner_width - 2, 0))
    [@ansi_gray, "│", @ansi_reset, fill, @ansi_gray, "│", @ansi_reset]
  end

  # Format an event-ticker entry as a natural-language line.
  #
  # The renderer is the one place that turns a `DebugLog` entry into
  # operator-facing text. Key rules surfaced by live testing:
  #
  # - Self-receive of agent.* echoes (140 received from 140) gets
  #   suppressed — the publish line already covered the same content.
  # - Cross-ticket receives use `←` instead of "Agent received from":
  #     `📬 140 ← 99: pushed "abc"`
  # - When the topic is a comment (issue.commented, pr.review_comment),
  #   the receive line reads `<id> new <Issue|PR> comment: "<body>"`.
  # - Pushes extract commits[*].message and report count + last msg.
  # - PRs (pr.opened / pr.merged) extract the PR title.
  # - Events without a meaningful body drop the trailing colon.
  defp format_event_line(%{kind: kind, topic: topic} = entry, rendering_identifier, repo) do
    if ticker_self_echo?(kind, topic, entry) do
      nil
    else
      glyph = event_glyph(kind)
      body = Map.get(entry, :body)
      source_id = event_source_ticket_id(topic)
      subject_id = event_subject_id(kind, entry, source_id, rendering_identifier)
      suffix = topic_suffix(topic)

      {verb_phrase, summary} = describe_event(kind, subject_id, source_id, suffix, body)

      # OSC 8 wraps. Subject id linkable to its issue; "PR" / "comment"
      # tokens in the verb phrase get wrapped with the body's URL when
      # available, falling back to the subject's issue URL.
      linked_subject = link_ticket_id(subject_id, repo)
      fallback_url = issue_url_for(subject_id, repo) || issue_url_for(source_id, repo)
      linked_verb = link_verb_phrase(verb_phrase, kind, suffix, body, repo, fallback_url)

      "#{glyph} #{linked_subject} #{linked_verb}#{summary}"
    end
  end

  defp format_event_line(_entry, _rendering_identifier, _repo), do: nil

  defp issue_url_for(id, repo) when is_binary(id) and is_binary(repo), do: issue_url(repo, id)
  defp issue_url_for(_id, _repo), do: nil

  defp event_glyph(:publish), do: "💬"
  defp event_glyph(:receive), do: "📬"
  defp event_glyph(:read), do: "📄"
  defp event_glyph(_), do: "·"

  defp event_source_ticket_id(topic) when is_binary(topic) do
    case Regex.run(~r/^ticket\.([^.]+)\./, topic) do
      [_, id] -> id
      _ -> nil
    end
  end

  defp event_source_ticket_id(_), do: nil

  # Suppress noisy self-receives: an agent's own subscription fanning
  # the agent.* event back to itself. The publish line above already
  # carries the same content. Comments (issue.commented /
  # pr.review_comment) survive because a comment on the agent's OWN
  # ticket is a genuine signal worth surfacing.
  defp ticker_self_echo?(:receive, topic, %{identifier: id})
       when is_binary(topic) and is_binary(id) do
    source = event_source_ticket_id(topic)
    suffix = topic_suffix(topic)

    source == id and not comment_topic?(suffix)
  end

  defp ticker_self_echo?(_kind, _topic, _entry), do: false

  defp comment_topic?("issue.commented"), do: true
  defp comment_topic?("pr.review_comment"), do: true
  defp comment_topic?(_), do: false

  # For publishes, the subject is the source ticket itself.
  # For receives / reads, the subject is the receiving ticket.
  defp event_subject_id(:publish, _entry, source_id, _rendering_identifier)
       when is_binary(source_id),
       do: source_id

  defp event_subject_id(:receive, %{identifier: id}, _source_id, _rendering_identifier)
       when is_binary(id),
       do: id

  defp event_subject_id(:read, %{identifier: id}, _source_id, _rendering_identifier)
       when is_binary(id),
       do: id

  defp event_subject_id(:read, _entry, source_id, _rendering_identifier)
       when is_binary(source_id),
       do: source_id

  defp event_subject_id(_kind, _entry, _source_id, rendering_identifier)
       when is_binary(rendering_identifier),
       do: rendering_identifier

  defp event_subject_id(_kind, _entry, _source_id, _rendering_identifier), do: "?"

  defp topic_suffix("ticket." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [_id, suffix] -> suffix
      _ -> rest
    end
  end

  defp topic_suffix(topic) when is_binary(topic), do: topic
  defp topic_suffix(_), do: ""

  # ── describe_event: {verb_phrase, summary} ──────────────────────────────
  # The verb phrase is the natural-language description of the topic.
  # The summary is "" or " \"…body…\"" depending on whether we found
  # something meaningful in the payload.

  # --- Self-comment on the agent's own ticket / PR ----------------------
  defp describe_event(:receive, subject_id, source_id, "issue.commented", body)
       when subject_id == source_id do
    {"new Issue comment:", comment_body_summary(body)}
  end

  defp describe_event(:receive, subject_id, source_id, "pr.review_comment", body)
       when subject_id == source_id do
    {"new PR comment:", comment_body_summary(body)}
  end

  # --- Cross-ticket receive: "<receiver> ← <source>: <verb>" ------------
  defp describe_event(:receive, _subject_id, source_id, suffix, body) when is_binary(source_id) do
    {"← #{source_id}: #{cross_receive_verb(suffix)}", cross_receive_summary(suffix, body)}
  end

  defp describe_event(:receive, _subject_id, _source_id, _suffix, _body) do
    {"received", ""}
  end

  # --- Read events (digest ingestion) ----------------------------------
  # A read entry is the receiver digesting an event from its inbox.
  # The line reads `📄 <receiver> ingested <source>: <publish-verb>"<body>"`
  # so the operator can see what the agent actually picked up. We
  # reuse `publish_event_phrase/2` for the verb + body so reads share
  # the same vocabulary as the originating publish line.
  defp describe_event(:read, subject_id, source_id, suffix, body)
       when is_binary(source_id) and source_id != subject_id do
    {verb, summary} = publish_event_phrase(suffix, body)
    {"ingested #{source_id}: #{verb}", summary}
  end

  defp describe_event(:read, _subject_id, _source_id, suffix, body) do
    {verb, summary} = publish_event_phrase(suffix, body)
    {"ingested: #{verb}", summary}
  end

  # --- Publishes -------------------------------------------------------
  defp describe_event(:publish, _subject_id, _source_id, suffix, body) do
    publish_event_phrase(suffix, body)
  end

  defp describe_event(_kind, _subject_id, _source_id, _suffix, _body), do: {"", ""}

  # ── Publish topic → {verb_phrase, summary} ─────────────────────────────
  # Verbs are written so the ID prefix reads as the implicit subject:
  #   `💬 99 started work: "..."` — not `💬 99 Agent started work: "..."`.
  # The leading "Agent" was dead weight that pushed real content off the
  # right edge in the bordered event log.

  defp publish_event_phrase("agent.phase." <> phase_step, body),
    do: {phrase_for_phase(phase_step) <> ":", inline_summary(body)}

  # The agent-driven progress sample. Carries `%{percent, label}`; the
  # label *is* the natural-language summary, so render the explicit
  # percent and let the operator read both.
  defp publish_event_phrase("agent.progress.checkin", body),
    do: progress_phrase("Check-in:", body)

  defp publish_event_phrase("agent.progress.phase", body),
    do: progress_phrase("Estimated progress:", body)

  defp publish_event_phrase("agent.progress", body),
    do: progress_phrase("Estimated progress:", body)

  defp publish_event_phrase("agent.blocked", body),
    do: {"blocked:", inline_summary(body)}

  defp publish_event_phrase("agent.unblocked", body),
    do: {"unblocked", inline_summary(body)}

  defp publish_event_phrase("agent.pause.request", body),
    do: {"requested pause", inline_summary(body)}

  defp publish_event_phrase("agent.attention." <> _slug, body),
    do: {"raised attention:", inline_summary(body)}

  defp publish_event_phrase("agent.decision." <> slug, body),
    do: {"decided #{slug}:", inline_summary(body)}

  defp publish_event_phrase("agent." <> name, body),
    do: {name <> ":", inline_summary(body)}

  defp publish_event_phrase("operator.progress_request", _body),
    do: {"check-in requested", ""}

  defp publish_event_phrase("issue.label.added.agent." <> state, body),
    do: {"labelled #{state}:", inline_summary(body)}

  defp publish_event_phrase("pr.opened", body),
    do: pr_event_phrase("opened a PR", body)

  defp publish_event_phrase("pr.merged", body),
    do: pr_event_phrase("merged a PR", body)

  defp publish_event_phrase("pr.review_comment", body),
    do: {"got a PR review comment:", comment_body_summary(body)}

  defp publish_event_phrase("ci.passed", _body), do: {"CI passed", ""}

  defp publish_event_phrase("ci.failed", body), do: {"CI failed:", inline_summary(body)}

  defp publish_event_phrase("branch.push", body),
    do: branch_push_phrase(body)

  defp publish_event_phrase("issue.commented", body),
    do: {"got an issue comment:", comment_body_summary(body)}

  defp publish_event_phrase(other, body),
    do: {other, inline_summary(body)}

  # Renders `<verb> N% done "label"` so the bar update reads in plain
  # English. Falls back to the raw inline_summary when the body has no
  # percent field (defensive — shouldn't happen in practice).
  defp progress_phrase(verb, body) do
    case progress_percent_from(body) do
      nil ->
        {verb, inline_summary(body)}

      pct ->
        suffix =
          case progress_label_from(body) do
            nil -> ""
            label -> " \"" <> clip_summary(label) <> "\""
          end

        {"#{verb} #{trunc(pct)}% done", suffix}
    end
  end

  defp progress_percent_from(body) when is_map(body) do
    cond do
      is_number(body[:percent]) -> body[:percent]
      is_number(body["percent"]) -> body["percent"]
      true -> nil
    end
  end

  defp progress_percent_from(_), do: nil

  defp progress_label_from(body) when is_map(body) do
    candidate = body[:label] || body["label"]
    if is_binary(candidate) and String.trim(candidate) != "", do: candidate
  end

  defp progress_label_from(_), do: nil

  defp pr_event_phrase(verb, body) do
    case pr_title(body) do
      nil -> {verb, ""}
      title -> {verb <> ":", " \"" <> clip_summary(title) <> "\""}
    end
  end

  defp branch_push_phrase(body) do
    commits = get_in_safe(body, [:commits]) || get_in_safe(body, ["commits"]) || []

    if is_list(commits) and commits != [] do
      count = length(commits)
      last = commits |> List.last() |> commit_message()

      case last do
        nil ->
          {"pushed #{count} #{commits_word(count)}", ""}

        msg ->
          {"pushed #{count} #{commits_word(count)}, last:", " \"" <> clip_summary(msg) <> "\""}
      end
    else
      {"pushed", ""}
    end
  end

  defp commits_word(1), do: "commit"
  defp commits_word(_), do: "commits"

  defp commit_message(%{} = commit) do
    Map.get(commit, "message") || Map.get(commit, :message)
  end

  defp commit_message(_), do: nil

  defp cross_receive_verb("branch.push"), do: "pushed"
  defp cross_receive_verb("pr.opened"), do: "opened a PR"
  defp cross_receive_verb("pr.merged"), do: "merged a PR"
  defp cross_receive_verb("pr.review_comment"), do: "PR review comment"
  defp cross_receive_verb("ci.passed"), do: "CI passed"
  defp cross_receive_verb("ci.failed"), do: "CI failed"
  defp cross_receive_verb("issue.commented"), do: "commented"
  defp cross_receive_verb("agent.unblocked"), do: "unblocked"
  defp cross_receive_verb("agent.blocked"), do: "blocked"
  defp cross_receive_verb("agent.phase." <> phase_step), do: phrase_for_phase(phase_step)
  defp cross_receive_verb("agent.progress"), do: "progress"
  defp cross_receive_verb("agent." <> name), do: name
  defp cross_receive_verb(other), do: other

  defp cross_receive_summary("branch.push", body) do
    case branch_push_phrase(body) do
      {_verb, ""} -> ""
      {_verb, summary} -> summary
    end
  end

  defp cross_receive_summary(suffix, body) when suffix in ["pr.opened", "pr.merged"] do
    case pr_title(body) do
      nil -> ""
      title -> " \"" <> clip_summary(title) <> "\""
    end
  end

  defp cross_receive_summary(suffix, body)
       when suffix in ["issue.commented", "pr.review_comment"] do
    comment_body_summary(body)
  end

  defp cross_receive_summary(_suffix, body), do: inline_summary(body)

  defp phrase_for_phase("brainstorm.start"), do: "started brainstorm"
  defp phrase_for_phase("brainstorm.end"), do: "finished brainstorm"
  defp phrase_for_phase("plan.start"), do: "started plan"
  defp phrase_for_phase("plan.end"), do: "finished plan"
  defp phrase_for_phase("work.start"), do: "started work"
  defp phrase_for_phase("work.end"), do: "finished work"
  defp phrase_for_phase("review.start"), do: "started review"
  defp phrase_for_phase("review.end"), do: "finished review"
  defp phrase_for_phase(other), do: "phase " <> other

  # ── Body extraction helpers ─────────────────────────────────────────────

  @summary_keys ~w(message title summary subject name label commit_message)

  defp inline_summary(body) when is_map(body) do
    case extract_event_text(body, @summary_keys) do
      nil -> ""
      text -> " \"" <> clip_summary(text) <> "\""
    end
  end

  defp inline_summary(_body), do: ""

  defp comment_body_summary(body) when is_map(body) do
    nested = get_in_safe(body, [:comment, "body"]) || get_in_safe(body, ["comment", "body"])

    if is_binary(nested) and String.trim(nested) != "" do
      " \"" <> clip_summary(String.trim(nested)) <> "\""
    else
      inline_summary(body)
    end
  end

  defp comment_body_summary(_body), do: ""

  defp pr_title(body) when is_map(body) do
    candidate = get_in_safe(body, [:pr, "title"]) || get_in_safe(body, ["pr", "title"])

    if is_binary(candidate) and String.trim(candidate) != "" do
      String.trim(candidate)
    end
  end

  defp pr_title(_body), do: nil

  defp extract_event_text(body, keys) do
    Enum.find_value(keys, fn k ->
      val = Map.get(body, k) || Map.get(body, String.to_atom(k))

      if is_binary(val) and String.trim(val) != "" do
        String.trim(val)
      end
    end)
  end

  defp clip_summary(text) when is_binary(text) do
    # Collapse every run of whitespace (including embedded newlines from
    # workpad markdown, code fences, multi-line comments) into a single
    # space so the terminal renders one row per event. Width-aware
    # truncation happens downstream in clip_and_pad/2, which is called
    # with the live pane width every render — that's why a resize
    # re-flows historical lines. Hard-capping here to a fixed character
    # count would defeat that and freeze old lines at the old width.
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp get_in_safe(nil, _path), do: nil
  defp get_in_safe(body, []), do: body

  defp get_in_safe(body, [key | rest]) when is_map(body) do
    case Map.get(body, key) do
      nil -> nil
      child -> get_in_safe(child, rest)
    end
  end

  defp get_in_safe(_body, _path), do: nil

  # ── OSC 8 hyperlinks ────────────────────────────────────────────────────
  # Modern terminals (iTerm2, Kitty, WezTerm, alacritty 0.11+, foot,
  # Windows Terminal, VSCode integrated terminal) interpret the OSC 8
  # escape as a clickable region — cmd-click opens the URL. tmux passes
  # the sequence through. Terminals without support just render the
  # plain text and ignore the escapes.

  defp repo_identity(state) do
    case Map.get(state, :repo_identity) || Map.get(state, :project_label) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp osc8(url, text) when is_binary(url) and is_binary(text) do
    "\e]8;;" <> url <> "\e\\" <> text <> "\e]8;;\e\\"
  end

  defp link_ticket_id(id, repo) when is_binary(id) and is_binary(repo) do
    osc8(issue_url(repo, id), id)
  end

  defp link_ticket_id(id, _repo) when is_binary(id), do: id

  defp issue_url(repo, id), do: "https://github.com/#{repo}/issues/#{id}"
  defp pr_url(repo, number), do: "https://github.com/#{repo}/pull/#{number}"

  # Linkify "PR" / "comment" tokens in the verb phrase. Falls back to
  # the subject's issue URL when the body has no PR-specific URL.
  defp link_verb_phrase(verb_phrase, _kind, suffix, body, repo, fallback_url)
       when is_binary(verb_phrase) do
    cond do
      repo == nil ->
        verb_phrase

      String.contains?(verb_phrase, "PR") and pr_linkable?(suffix) ->
        wrap_token(verb_phrase, "PR", pr_link_target(body, repo, fallback_url))

      String.contains?(verb_phrase, "comment") ->
        wrap_token(verb_phrase, "comment", comment_link_target(body, suffix, fallback_url))

      true ->
        verb_phrase
    end
  end

  defp pr_linkable?("pr.opened"), do: true
  defp pr_linkable?("pr.merged"), do: true
  defp pr_linkable?("pr.review_comment"), do: true
  defp pr_linkable?(_), do: false

  defp pr_link_target(body, repo, fallback) when is_map(body) do
    pr_html_url(body) || pr_number_url(body, repo) || fallback
  end

  defp pr_link_target(_body, _repo, fallback), do: fallback

  defp pr_html_url(body) do
    candidate = get_in_safe(body, [:pr, "html_url"]) || get_in_safe(body, ["pr", "html_url"])
    if is_binary(candidate) and candidate != "", do: candidate
  end

  defp pr_number_url(body, repo) do
    case get_in_safe(body, [:pr, "number"]) || get_in_safe(body, ["pr", "number"]) do
      n when is_integer(n) -> pr_url(repo, n)
      n when is_binary(n) and n != "" -> pr_url(repo, n)
      _ -> nil
    end
  end

  defp comment_link_target(body, suffix, fallback) when is_map(body) do
    candidate =
      get_in_safe(body, [:comment, "html_url"]) || get_in_safe(body, ["comment", "html_url"])

    cond do
      is_binary(candidate) and candidate != "" -> candidate
      suffix == "pr.review_comment" -> pr_html_url(body) || fallback
      true -> fallback
    end
  end

  defp comment_link_target(_body, _suffix, fallback), do: fallback

  # Wraps the first occurrence of `token` in `text` with an OSC 8
  # link. No-op when target is nil/empty.
  defp wrap_token(text, _token, target) when target in [nil, ""], do: text

  defp wrap_token(text, token, target) when is_binary(target) do
    case :binary.match(text, token) do
      :nomatch ->
        text

      {start, length} ->
        {prefix, rest} = String.split_at(text, start)
        {match, suffix} = String.split_at(rest, length)
        prefix <> osc8(target, match) <> suffix
    end
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
