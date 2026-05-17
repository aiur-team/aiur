defmodule SymphonyPane.Viewport do
  @moduledoc """
  Renders a conversation pane: transcript region above, composer region below.

  Uses cursor home (`\\e[H`) plus per-line `\\e[K` (clear-to-end-of-line)
  instead of full-screen `\\e[2J` so the terminal does not flash between
  frames.

  Composer chrome (deepened): one blank row above the input, the input
  row with a subtle dark background, one blank row below. SGR reset
  emitted before `\\r\\n` per ANSI portability guidance so the
  background tint never bleeds into the next row on Termius / iTerm2.
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

  # ANSI palette (kept aligned with `SymphonyElixir.AgentList.Renderer`).
  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_dim IO.ANSI.faint()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_gray IO.ANSI.light_black()
  @ansi_input_bg "\e[48;5;236m"
  @ansi_input_fg "\e[38;5;255m"

  # Rows the composer block consumes (blank, tinted input, blank).
  @composer_rows 3

  @spec render(state()) :: {iodata(), {pos_integer(), pos_integer()}}
  def render(%{transcript: transcript, composer: composer, columns: cols, rows: rows} = state) do
    inner_width = max(cols - 1, 1)
    transcript_rows = max(rows - @composer_rows, 1)

    transcript_lines = transcript_iolist(state.identifier, transcript, transcript_rows, inner_width)
    {composer_lines, cursor_col} = composer_iolist(composer, inner_width)

    frame = [
      "\e[H",
      transcript_lines,
      composer_lines
    ]

    cursor_row = rows - 1
    {frame, {cursor_row, cursor_col}}
  end

  # ---------- transcript ----------------------------------------------------

  defp transcript_iolist(identifier, events, transcript_rows, inner_width) do
    header_line = header_line(identifier, inner_width)

    body_budget = max(transcript_rows - 1, 0)
    visible_events = Enum.take(events, -body_budget)

    body_lines =
      Enum.map(visible_events, fn event ->
        pad_line(format_event(event), inner_width)
      end)

    padding_lines = body_budget - length(visible_events)
    blanks = List.duplicate(blank_line(inner_width), max(padding_lines, 0))

    rows = [header_line | body_lines ++ blanks]

    rows
    |> Enum.flat_map(fn row -> [row, eol()] end)
  end

  defp header_line(identifier, inner_width) do
    text = " Symphony — #{identifier}"
    pad_with_ansi(@ansi_bold <> @ansi_cyan, text, inner_width)
  end

  # ---------- composer ------------------------------------------------------

  defp composer_iolist(%{buffer: buffer, cursor: cursor}, inner_width) do
    prompt = @prompt
    prompt_len = String.length(prompt)
    available = max(inner_width - prompt_len, 0)
    visible_buffer = String.slice(buffer, 0, available)
    visible_line = prompt <> visible_buffer
    padded_line = String.pad_trailing(visible_line, inner_width)

    blank = blank_line(inner_width)
    tinted = [@ansi_input_bg, @ansi_input_fg, padded_line, @ansi_reset]

    cursor_col = prompt_len + min(cursor, available) + 1

    lines = [
      blank,
      eol(),
      tinted,
      eol(),
      blank,
      eol()
    ]

    {lines, cursor_col}
  end

  # ---------- helpers -------------------------------------------------------

  defp format_event(%{role: :user, body: body}), do: "you: " <> body
  defp format_event(%{role: :assistant, body: body}), do: "agent: " <> body
  defp format_event(%{role: :system, body: body}), do: "* " <> body
  defp format_event(_other), do: ""

  defp pad_line(text, inner_width) do
    safe = String.slice(text, 0, inner_width)
    pad = String.duplicate(" ", max(inner_width - String.length(safe), 0))
    [safe, pad]
  end

  defp pad_with_ansi(ansi, text, inner_width) do
    safe = String.slice(text, 0, inner_width)
    pad = String.duplicate(" ", max(inner_width - String.length(safe), 0))
    [ansi, safe, @ansi_reset, pad]
  end

  defp blank_line(inner_width), do: String.duplicate(" ", inner_width)

  # SGR reset BEFORE \r\n (per the ANSI deepen pass) is what `@ansi_reset`
  # placed at the end of each colored span enforces. `\e[K` then clears any
  # residual content from a previous frame at this row.
  defp eol, do: ["\e[K", "\r\n"]

  # Suppress unused warnings for palette members we may use in future tweaks.
  _ = @ansi_yellow
  _ = @ansi_dim
  _ = @ansi_gray
end
