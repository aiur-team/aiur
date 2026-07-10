defmodule Aiur.AgentList.Renderer.Chrome do
  @moduledoc """
  Renders bordered chrome, metadata, and footer keybind rows.
  """

  alias Aiur.AgentList.Renderer.{Style, Text}

  # ---------- header / metadata ---------------------------------------------

  def title_row(inner_width) do
    title = "╭─ AIUR"
    title_visual = Text.visual_width(title)

    # `╮` rounded corner reserved at the far right; padding fills the gap
    # between the AIUR title and the corner.
    pad_count = max(inner_width - title_visual - 1, 1)
    pad = String.duplicate(" ", pad_count)

    [Style.bold(), title, Style.reset(), pad, Style.gray(), "╮", Style.reset()]
  end

  def metadata_rows(state, inner_width) do
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

  def agents_row(kind, count, max, focused?, alert?, inner_width)
      when is_integer(count) and is_integer(max) and max > 0 do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    agents_row_iolist(kind_value, count, max, focused?, alert?, inner_width)
  end

  def agents_row(kind, count, _max, _focused?, _alert?, inner_width) when is_integer(count) do
    kind_value = if is_binary(kind) and kind != "", do: kind, else: "agents"
    metadata_row_iolist("Agents:", "#{kind_value} (#{count})", Style.cyan(), inner_width)
  end

  def agents_row(_kind, _count, _max, _focused?, _alert?, inner_width),
    do: metadata_row_iolist("Agents:", "n/a", Style.gray(), inner_width)

  def project_row(nil, inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  def project_row("", inner_width),
    do: metadata_row_iolist("Project:", "n/a", Style.gray(), inner_width)

  def project_row(label, inner_width),
    do: metadata_row_iolist("Project:", label, Style.cyan(), inner_width)

  def dashboard_row(nil, inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  def dashboard_row("", inner_width),
    do: metadata_row_iolist("Dashboard:", "n/a", Style.gray(), inner_width)

  def dashboard_row(url, inner_width),
    do: metadata_row_iolist("Dashboard:", url, Style.cyan(), inner_width)

  def metadata_row_iolist(label, value, value_color, inner_width) do
    prefix = "│ "
    bold_label = Style.bold() <> label <> Style.reset()
    colored_value = value_color <> value <> Style.reset()
    plain = prefix <> label <> " " <> value
    pad = Text.padding_for(plain, inner_width)
    [prefix, bold_label, " ", colored_value, pad]
  end

  def agents_row_iolist(kind, count, max, focused?, alert?, inner_width) do
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

  def separator_row(inner_width) do
    [
      Text.pad_with_ansi(
        Style.gray(),
        "├" <> String.duplicate("─", max(inner_width - 2, 0)),
        inner_width,
        "┤"
      )
    ]
  end

  def bottom_border(inner_width) do
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
  def footer_split(inner_width, rc_line) do
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

  def footer_keybinds_split(inner_width) do
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
  def rc_footer_text(state) do
    case Map.get(state, :remote_control_hint) do
      hint when is_binary(hint) and hint != "" -> hint
      _ -> nil
    end
  end

  def left_only_row(text, inner_width) do
    body = String.duplicate(" ", @footer_left_padding) <> text
    Text.pad_with_ansi(Style.dim(), body, inner_width, " ")
  end
end
