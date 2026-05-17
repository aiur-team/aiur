defmodule SymphonyPane.Viewport do
  @moduledoc """
  Renders a conversation pane: transcript region above, composer region below.

  Full-frame rendering for Phase 1 (clear + redraw). Reserves the final
  column to avoid autowrap on SSH clients. The terminal cursor is
  positioned at the composer cursor on every frame so the user sees a
  real cursor in the input line.

  Phase 2 follow-up: line-by-line diff against last-rendered state for
  the per-keystroke `<200μs` budget called out in the plan.
  """

  alias SymphonyElixir.AgentEvents
  alias SymphonyPane.Composer

  @type state :: %{
          identifier: String.t(),
          transcript: [AgentEvents.transcript_event()],
          composer: Composer.t(),
          columns: pos_integer(),
          rows: pos_integer()
        }

  @prompt "> "

  @spec render(state()) :: {iodata(), {pos_integer(), pos_integer()}}
  def render(%{transcript: transcript, composer: composer, columns: cols, rows: rows} = state) do
    inner_width = max(cols - 1, 1)
    transcript_rows = max(rows - 3, 1)

    transcript_lines = transcript_iolist(state.identifier, transcript, transcript_rows, inner_width)
    {composer_lines, cursor_col} = composer_iolist(composer, inner_width)

    frame = [
      "\e[2J\e[H",
      transcript_lines,
      pad_line(String.duplicate("─", inner_width), inner_width),
      "\r\n",
      composer_lines
    ]

    cursor_row = rows
    {frame, {cursor_row, cursor_col}}
  end

  defp transcript_iolist(identifier, events, transcript_rows, inner_width) do
    header_line = pad_line("Symphony — #{identifier}", inner_width)

    visible_events = Enum.take(events, -(transcript_rows - 1))

    body_lines =
      Enum.map(visible_events, fn event ->
        pad_line(format_event(event), inner_width)
      end)

    padding_lines = transcript_rows - 1 - length(visible_events)

    blanks = List.duplicate(pad_line("", inner_width), max(padding_lines, 0))

    Enum.intersperse([header_line | body_lines ++ blanks], "\r\n") ++ ["\r\n"]
  end

  defp composer_iolist(%{buffer: buffer, cursor: cursor}, inner_width) do
    prompt_text = @prompt <> buffer
    line = pad_line(prompt_text, inner_width)
    {line, String.length(@prompt) + min(cursor, inner_width - String.length(@prompt)) + 1}
  end

  defp format_event(%{role: :user, body: body}), do: "you: " <> body
  defp format_event(%{role: :assistant, body: body}), do: "agent: " <> body
  defp format_event(%{role: :system, body: body}), do: "* " <> body
  defp format_event(_other), do: ""

  defp pad_line(text, inner_width) do
    safe = String.slice(text, 0, inner_width)
    [safe, String.duplicate(" ", inner_width - String.length(safe))]
  end
end
