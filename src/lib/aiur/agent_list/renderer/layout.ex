defmodule Aiur.AgentList.Renderer.Layout do
  @moduledoc """
  Computes responsive column widths and owns the fixed table dimensions.
  """

  alias Aiur.AgentList.Renderer.Model

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

  @spec state_cell_width() :: pos_integer()
  def state_cell_width, do: @state_cell_width
  @spec attention_cell_width() :: pos_integer()
  def attention_cell_width, do: @attention_cell_width
  @spec rc_cell_width() :: pos_integer()
  def rc_cell_width, do: @rc_cell_width
  @spec progress_cell_width() :: pos_integer()
  def progress_cell_width, do: @progress_cell_width
  @spec progress_bar_width() :: pos_integer()
  def progress_bar_width, do: @progress_bar_width
  @spec runtime_cell_width() :: pos_integer()
  def runtime_cell_width, do: @runtime_cell_width
  @spec min_id_width() :: pos_integer()
  def min_id_width, do: @min_id_width
  @spec min_title_width() :: pos_integer()
  def min_title_width, do: @min_title_width
  @spec max_latest_width() :: pos_integer()
  def max_latest_width, do: @max_latest_width
  @spec title_constrained_cap() :: pos_integer()
  def title_constrained_cap, do: @title_constrained_cap
  @spec model_base_width() :: pos_integer()
  def model_base_width, do: Model.base_width()

  # Compute per-frame column widths so identifiers only take as much
  # space as they actually need, leaving the rest for the title.
  # Recomputed on every render so a wider pane reflows immediately
  # when tmux resizes.
  def compute(summaries, inner_width) do
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
      |> Enum.map(&Model.model_natural_width/1)
      |> Enum.max(fn -> 0 end)
      |> max(Model.base_width())

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

    # The MODEL base column reserves Model.base_width() (+ a separator),
    # mirroring the PROGRESS drop pattern: it shows only when there's room
    # for it beyond the id/title/latest minimums, so at extreme narrowness it
    # drops *after* TITLE/LATEST are already at their minimums — never before.
    show_model? =
      inner_width - base_overhead - progress_block_width - @min_id_width - @min_title_width -
        @min_latest_width - 1 >= Model.base_width() + 1

    model_base_block = if show_model?, do: Model.base_width() + 1, else: 0
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
        leftover >= natural_model_width - Model.base_width() -> natural_model_width
        true -> Model.base_width()
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
end
