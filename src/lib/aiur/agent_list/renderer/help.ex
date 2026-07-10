defmodule Aiur.AgentList.Renderer.Help do
  @moduledoc """
  Renders the keybind and state-circle help overlay.
  """

  alias Aiur.AgentList.Renderer.{Chrome, Style, Text}

  def render(inner_width) do
    body_rows = help_body_rows(inner_width)
    body_count = length(body_rows)

    drawn =
      [
        "\e[H",
        Chrome.title_row(inner_width),
        Text.eol(),
        Chrome.separator_row(inner_width),
        Text.eol()
      ] ++
        Enum.flat_map(body_rows, fn row -> [row, Text.eol()] end) ++
        [
          Chrome.bottom_border(inner_width),
          Text.eol(),
          help_footer_row(inner_width),
          Text.eol()
        ]

    # 5 fixed chrome rows (title, separator, bottom border, footer) +
    # 1 newline after each + the help body rows.
    drawn_count = 4 + body_count
    {drawn, drawn_count}
  end

  def help_body_rows(inner_width) do
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

  def help_heading_row(text, inner_width) do
    prefix = "│ "
    bold = Style.bold() <> text <> Style.reset()
    plain = prefix <> text
    pad = Text.padding_for(plain, inner_width)
    [prefix, bold, pad]
  end

  def help_line_row(text, inner_width) do
    prefix = "│   "
    plain = prefix <> text
    pad_width = max(inner_width - Text.visual_width(plain), 0)
    pad = String.duplicate(" ", pad_width)
    [prefix, text, pad]
  end

  def help_blank_row(inner_width) do
    pad = String.duplicate(" ", max(inner_width - 1, 0))
    ["│", pad]
  end

  def help_footer_row(inner_width) do
    text = "  ? close help   q quit"
    Text.pad_with_ansi(Style.dim(), text, inner_width, " ")
  end
end
