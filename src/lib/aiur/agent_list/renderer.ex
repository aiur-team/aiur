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
  alias Aiur.AgentList.Renderer.{EventsBlock, Links, Style, Text}
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
  @model_ansi %{opus: Style.magenta(), sonnet: Style.blue(), codex: Style.green()}

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
      {events_iodata, events_line_count} = EventsBlock.events_block(state, inner_width, events_budget)

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
        Text.eol(),
        metadata_rows(state, inner_width),
        separator_row(inner_width),
        Text.eol(),
        table_header_row(inner_width, layout),
        Text.eol(),
        table_separator_row(inner_width, layout),
        Text.eol(),
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
        Text.eol(),
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
        Text.eol(),
        separator_row(inner_width),
        Text.eol()
      ] ++
        Enum.flat_map(body_rows, fn row -> [row, Text.eol()] end) ++
        [
          bottom_border(inner_width),
          Text.eol(),
          help_footer_row(inner_width),
          Text.eol()
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
    bold = Style.bold() <> text <> Style.reset()
    plain = prefix <> text
    pad = Text.padding_for(plain, inner_width)
    [prefix, bold, pad]
  end

  defp help_line_row(text, inner_width) do
    prefix = "│   "
    plain = prefix <> text
    pad_width = max(inner_width - Text.visual_width(plain), 0)
    pad = String.duplicate(" ", pad_width)
    [prefix, text, pad]
  end

  defp help_blank_row(inner_width) do
    pad = String.duplicate(" ", max(inner_width - 1, 0))
    ["│", pad]
  end

  defp help_footer_row(inner_width) do
    text = "  ? close help   q quit"
    Text.pad_with_ansi(Style.dim(), text, inner_width, " ")
  end

  # ---------- header / metadata ---------------------------------------------

  defp title_row(inner_width) do
    title = "╭─ AIUR"
    title_visual = Text.visual_width(title)

    # `╮` rounded corner reserved at the far right; padding fills the gap
    # between the AIUR title and the corner.
    pad_count = max(inner_width - title_visual - 1, 1)
    pad = String.duplicate(" ", pad_count)

    [Style.bold(), title, Style.reset(), pad, Style.gray(), "╮", Style.reset()]
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
      Text.eol(),
      project_row(Map.get(state, :project_label), inner_width),
      Text.eol(),
      dashboard_row(Map.get(state, :dashboard_url), inner_width),
      Text.eol()
    ]
  end

  defp agents_row(kind, count, max, focused?, alert?, inner_width)
       when is_integer(count) and is_integer(max) and max > 0 do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    agents_row_iolist(kind_value, count, max, focused?, alert?, inner_width)
  end

  defp agents_row(kind, count, _max, _focused?, _alert?, inner_width) when is_integer(count) do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    metadata_row_iolist("Agents:", "#{kind_value} (#{count})", Style.cyan(), inner_width)
  end

  defp agents_row(_kind, _count, _max, _focused?, _alert?, inner_width),
    do: metadata_row_iolist("Agents:", "n/a", Style.gray(), inner_width)

  defp project_row(nil, inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  defp project_row("", inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  defp project_row(label, inner_width),
    do: metadata_row_iolist("Project:", label, Style.cyan(), inner_width)

  defp dashboard_row(nil, inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  defp dashboard_row("", inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  defp dashboard_row(url, inner_width),
    do: metadata_row_iolist("Dashboard:", url, Style.cyan(), inner_width)

  defp metadata_row_iolist(label, value, value_color, inner_width) do
    prefix = "│ "
    bold_label = Style.bold() <> label <> Style.reset()
    colored_value = value_color <> value <> Style.reset()
    plain = prefix <> label <> " " <> value
    pad = Text.padding_for(plain, inner_width)
    [prefix, bold_label, " ", colored_value, pad]
  end

  defp agents_row_iolist(kind, count, max, focused?, alert?, inner_width) do
    label = "Agents:"
    prefix = "│ "
    bold_label = Style.bold() <> label <> Style.reset()
    max_text = if focused?, do: "[#{max}]", else: to_string(max)
    affordance = if focused?, do: "  ← →", else: ""
    drain_text = if count > max, do: " drain", else: ""
    plain = "#{prefix}#{label} #{kind} (#{count}/#{max_text}#{drain_text})#{affordance}"
    pad = Text.padding_for(plain, inner_width)

    max_style =
      cond do
        alert? -> Style.red() <> Style.reverse()
        focused? -> Style.reverse()
        true -> Style.cyan()
      end

    [
      prefix,
      bold_label,
      " ",
      Style.cyan(),
      kind,
      " (",
      Integer.to_string(count),
      "/",
      max_style,
      max_text,
      Style.reset(),
      Style.cyan(),
      drain_text,
      ")",
      affordance,
      Style.reset(),
      pad
    ]
  end

  defp separator_row(inner_width) do
    [
      Text.pad_with_ansi(
        Style.gray(),
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
        Style.gray(),
        "╰─ ",
        Style.reset(),
        Style.gray(),
        IO.ANSI.italic(),
        label_text,
        Style.reset(),
        Style.gray(),
        " ",
        trailing_fill,
        "╯",
        Style.reset()
      ]
    else
      [
        Text.pad_with_ansi(
          Style.gray(),
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
            Text.truncate(text, max(inner_width - @footer_left_padding - 1, 0)),
            inner_width
          ),
          Text.eol()
        ]

        %{iodata: [rc_row | base.iodata], line_count: base.line_count + 1}

      _ ->
        base
    end
  end

  defp footer_keybinds_split(inner_width) do
    if Text.visual_width(@footer_left_padding_str <> @keybinds_full) + 1 <= inner_width do
      %{iodata: [left_only_row(@keybinds_full, inner_width), Text.eol()], line_count: 1}
    else
      %{
        iodata: [
          left_only_row(@keybinds_primary, inner_width),
          Text.eol(),
          left_only_row(@keybinds_secondary, inner_width),
          Text.eol()
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
    Text.pad_with_ansi(Style.dim(), body, inner_width, " ")
  end

  # ---------- table ----------------------------------------------------------

  defp table_header_row(inner_width, layout) do
    progress_header =
      if layout.show_progress?, do: [" ", Text.cell("PROGRESS", @progress_cell_width)], else: []

    runtime_header = [" ", Text.cell("TIME", @runtime_cell_width)]

    model_header =
      if layout.model_width > 0, do: [Text.cell("MODEL", layout.model_width), " "], else: []

    body = [
      "│   ",
      Text.cell("ID", layout.id_width),
      Text.cell("", @rc_cell_width),
      Text.cell("", @state_cell_width),
      Text.cell("", @attention_cell_width),
      model_header,
      Text.cell("TITLE", layout.title_width),
      " ",
      Text.cell("LATEST", layout.latest_width),
      progress_header,
      runtime_header
    ]

    Text.pad_with_ansi(Style.gray(), IO.iodata_to_binary(body), inner_width)
  end

  defp table_separator_row(inner_width, _layout) do
    # Full-width horizontal rule from `├` to `┤`, matching the
    # other section dividers above and below so the box closes
    # cleanly on both sides. Previously the dashes stopped at the
    # column-totals width and the rest of the row was blank space —
    # the right `│` border ended up disconnected from the divider.
    [
      Text.pad_with_ansi(
        Style.gray(),
        "├" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "┤"
      )
    ]
  end

  defp render_rows([], _idx, _selection_focus, inner_width, layout, _markers) do
    [
      Text.pad_with_ansi(Style.dim(), "│   " <> empty_body_text(layout), inner_width),
      Text.eol()
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
        Text.eol()
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
    state_cell = Text.emoji_cell(summary_emoji(summary, markers, phase), @state_cell_width)
    attention_cell = attention_cell(id_str, layout)
    title_cell = Text.cell(title, layout.title_width)
    latest_cell = latest_cell(id_str, layout, summary)
    model_block = model_cell_block(summary, layout)

    progress_block =
      if layout.show_progress? do
        [" ", Style.dim(), progress_cell(id_str, layout), Style.reset()]
      else
        []
      end

    runtime_block = [" ", Style.dim(), runtime_cell(summary), Style.reset()]

    body = [
      "│ ",
      marker,
      Style.cyan(),
      id_cell,
      Style.reset(),
      rc_cell(summary),
      state_cell,
      attention_cell,
      model_block,
      title_cell,
      " ",
      Style.dim(),
      latest_cell,
      Style.reset(),
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
        |> Text.strip_csi()

      [Style.reverse(), highlighted, Style.reset(), Style.gray(), "│", Style.reset()]
    else
      [row, Style.gray(), "│", Style.reset()]
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
    padded = Text.cell(id_str, layout.id_width)
    project = Map.get(layout, :project_label)

    case Links.ticket_url(project, id_str) do
      nil -> padded
      url -> "\e]8;;" <> url <> "\e\\" <> padded <> "\e]8;;\e\\"
    end
  end

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

    Text.emoji_cell(text, @attention_cell_width)
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

    Text.emoji_cell(glyph, @rc_cell_width)
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
  # otherwise wrapped in `Style.dim()` at the call site; we reset and
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
        Style.reset() <> Style.green() <> full_bar <> Style.reset() <> Style.dim()

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
    Text.cell(format_runtime(seconds), @runtime_cell_width)
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

      Text.cell(text, layout.latest_width)
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
      padded = Text.cell(text, width)

      case model_color(family, Map.get(layout, :truecolor?, true)) do
        # Families with no website color: dim the queued/unknown `–`
        # placeholder (family nil); leave a generic claude/haiku name in the
        # default foreground.
        nil when is_nil(family) -> [Style.dim(), padded, Style.reset(), " "]
        nil -> [padded, " "]
        color -> [color, padded, Style.reset(), " "]
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
