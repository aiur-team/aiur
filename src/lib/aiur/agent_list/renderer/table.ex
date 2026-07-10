defmodule Aiur.AgentList.Renderer.Table do
  @moduledoc """
  Renders table headers, rows, selection highlighting, and empty states.
  """

  alias Aiur.AgentList.Renderer.{Cells, Layout, Markers, Model, Style, Text}

  # ---------- table ----------------------------------------------------------

  def table_header_row(inner_width, layout) do
    progress_header =
      if layout.show_progress?, do: [" ", Text.cell("PROGRESS", Layout.progress_cell_width())], else: []

    runtime_header = [" ", Text.cell("TIME", Layout.runtime_cell_width())]

    model_header =
      if layout.model_width > 0, do: [Text.cell("MODEL", layout.model_width), " "], else: []

    body = [
      "│   ",
      Text.cell("ID", layout.id_width),
      Text.cell("", Layout.rc_cell_width()),
      Text.cell("", Layout.state_cell_width()),
      Text.cell("", Layout.attention_cell_width()),
      model_header,
      Text.cell("TITLE", layout.title_width),
      " ",
      Text.cell("LATEST", layout.latest_width),
      progress_header,
      runtime_header
    ]

    Text.pad_with_ansi(Style.gray(), IO.iodata_to_binary(body), inner_width)
  end

  def table_separator_row(inner_width, _layout) do
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

  def render_rows([], _idx, _selection_focus, inner_width, layout, _markers) do
    [
      Text.pad_with_ansi(Style.dim(), "│   " <> empty_body_text(layout), inner_width),
      Text.eol()
    ]
  end

  def render_rows(summaries, idx, selection_focus, inner_width, layout, markers) do
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
  def empty_body_text(layout) do
    if Map.get(layout, :prewarm_active?, false) do
      Cells.spinner_frame(layout) <> " Pre-warming base (" <> prewarm_label(Map.get(layout, :prewarm_phase)) <> ")…"
    else
      "(no agents running)"
    end
  end

  def prewarm_label(:cloning), do: "cloning"
  def prewarm_label(:fetching), do: "fetching main"
  def prewarm_label(:building), do: "compiling"
  def prewarm_label(_phase), do: "warming up"

  def render_row(summary, selected?, inner_width, layout, markers) do
    marker = if selected?, do: "▶ ", else: "  "
    id_str = to_string(Map.get(summary, :identifier) || "")
    title = Map.get(summary, :title) || ""

    id_cell = Cells.id_cell_with_link(id_str, layout)
    phase = Map.get(Map.get(layout, :phase_by_identifier, %{}), id_str)
    state_cell = Text.emoji_cell(Markers.summary_emoji(summary, markers, phase), Layout.state_cell_width())
    attention_cell = Cells.attention_cell(id_str, layout)
    title_cell = Text.cell(title, layout.title_width)
    latest_cell = Cells.latest_cell(id_str, layout, summary)
    model_block = Model.model_cell_block(summary, layout)

    progress_block =
      if layout.show_progress? do
        [" ", Style.dim(), Cells.progress_cell(id_str, layout), Style.reset()]
      else
        []
      end

    runtime_block = [" ", Style.dim(), Cells.runtime_cell(summary), Style.reset()]

    body = [
      "│ ",
      marker,
      Style.cyan(),
      id_cell,
      Style.reset(),
      Cells.rc_cell(summary),
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

    progress_width = if layout.show_progress?, do: Layout.progress_cell_width() + 1, else: 0
    runtime_width = Layout.runtime_cell_width() + 1
    model_width = if layout.model_width > 0, do: layout.model_width + 1, else: 0

    # Visual columns consumed by the body, in order:
    #   `│ ` (2) + marker (2) + id_cell + rc_cell (3)
    #   + state_cell (3) + attention_cell (4) + model_block + title_cell
    #   + ` ` (1) + latest_cell + progress_block + runtime_block.
    # Sum the parts directly so the right `│` border lands at the
    # same column as the metadata/separator rows above.
    plain_visual =
      2 + 2 + layout.id_width + Layout.rc_cell_width() + Layout.state_cell_width() + Layout.attention_cell_width() +
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
end
