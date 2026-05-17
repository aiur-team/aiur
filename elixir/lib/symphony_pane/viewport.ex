defmodule SymphonyPane.Viewport do
  @moduledoc """
  Renders a conversation pane: transcript region above, composer region below.

  Uses cursor home (`\\e[H`) plus per-line `\\e[K` (clear-to-end-of-line)
  instead of full-screen `\\e[2J` so the terminal does not flash between
  frames.

  Composer chrome: one blank row above the input, one or more tinted-bg
  input rows (the buffer wraps to the next row when it exceeds the pane
  width), and one blank row below. SGR reset is emitted before `\\r\\n`
  so the background tint never bleeds onto the next row on
  Termius / iTerm2.
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

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_input_bg "\e[48;5;236m"
  @ansi_input_fg "\e[38;5;255m"

  # Max tinted-input rows before we stop growing the composer block. Beyond
  # this we truncate from the start of the buffer (keeping the cursor and
  # tail visible) rather than letting it swallow the transcript.
  @max_input_rows 6

  @spec render(state()) :: {iodata(), {pos_integer(), pos_integer()}}
  def render(%{transcript: transcript, composer: composer, columns: cols, rows: rows} = state) do
    inner_width = max(cols - 1, 1)

    {composer_lines, composer_meta} = composer_iolist(composer, inner_width)
    total_composer_rows = composer_meta.input_rows + 2
    transcript_rows = max(rows - total_composer_rows, 1)

    transcript_lines = transcript_iolist(state.identifier, transcript, transcript_rows, inner_width)

    frame = [
      "\e[H",
      transcript_lines,
      composer_lines
    ]

    # Pane layout (1-indexed):
    #   rows 1..transcript_rows                            transcript
    #   row  transcript_rows + 1                           composer top blank
    #   rows transcript_rows + 2 .. + input_rows + 1       tinted input rows
    #   row  transcript_rows + 2 + input_rows              composer bottom blank
    cursor_row = transcript_rows + 2 + composer_meta.cursor_segment_index
    {frame, {cursor_row, composer_meta.cursor_col}}
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
    prompt_len = String.length(@prompt)
    first_capacity = max(inner_width - prompt_len, 1)

    %{
      segments: segments,
      cursor_segment_index: cursor_segment_index,
      cursor_col_in_segment: cursor_col_in_segment,
      shows_buffer_start: shows_buffer_start
    } = wrap_buffer(buffer, cursor, first_capacity, inner_width)

    input_rows = length(segments)

    tinted_rows =
      segments
      |> Enum.with_index()
      |> Enum.map(fn {segment, idx} ->
        prefix = if idx == 0 and shows_buffer_start, do: @prompt, else: ""
        line = prefix <> segment
        padded = String.pad_trailing(line, inner_width)
        [@ansi_input_bg, @ansi_input_fg, padded, @ansi_reset]
      end)

    blank = blank_line(inner_width)

    lines =
      [blank, eol()] ++
        Enum.flat_map(tinted_rows, fn row -> [row, eol()] end) ++
        [blank, "\e[K"]

    # Account for the prompt on the cursor's row only when that row is the
    # buffer's actual first row (i.e. we did not trim the top).
    prefix_len = if cursor_segment_index == 0 and shows_buffer_start, do: prompt_len, else: 0
    cursor_col = prefix_len + cursor_col_in_segment + 1

    meta = %{
      input_rows: input_rows,
      cursor_segment_index: cursor_segment_index,
      cursor_col: cursor_col
    }

    {lines, meta}
  end

  # Split `buffer` into row-sized chunks so that:
  #   * the first row holds at most `first_capacity` characters (the prompt
  #     takes the rest of the first row),
  #   * each subsequent row holds at most `width` characters,
  #   * the cursor's position is translated to {row_index, col_in_row}.
  # When the buffer would need more than `@max_input_rows` rows, drop the
  # earliest segments so the cursor stays visible. After trimming, the
  # visible composer no longer shows the buffer's first row, so
  # `shows_buffer_start` is false and we suppress the `> ` prompt
  # (otherwise we'd accidentally prepend it to a continuation chunk and
  # overflow the row width).
  defp wrap_buffer(buffer, cursor, first_capacity, width) do
    chars = String.graphemes(buffer)
    segments = split_into_segments(chars, first_capacity, width, [])
    segments = if segments == [], do: [""], else: segments

    {cursor_segment, cursor_col} = cursor_position(cursor, first_capacity, width)

    {visible_segments, cursor_index, shows_buffer_start} =
      maybe_trim_top(segments, cursor_segment, @max_input_rows)

    %{
      segments: visible_segments,
      cursor_segment_index: cursor_index,
      cursor_col_in_segment: cursor_col,
      shows_buffer_start: shows_buffer_start
    }
  end

  defp split_into_segments([], _first_capacity, _width, acc), do: Enum.reverse(acc)

  defp split_into_segments(chars, first_capacity, width, []) do
    {head, rest} = take_segment(chars, first_capacity)
    split_into_segments(rest, first_capacity, width, [head])
  end

  defp split_into_segments(chars, first_capacity, width, acc) do
    {head, rest} = take_segment(chars, width)
    split_into_segments(rest, first_capacity, width, [head | acc])
  end

  defp take_segment(chars, capacity) do
    {head, rest} = Enum.split(chars, capacity)
    {Enum.join(head), rest}
  end

  defp cursor_position(cursor, first_capacity, width) do
    if cursor <= first_capacity do
      {0, cursor}
    else
      remainder = cursor - first_capacity
      row = 1 + div(remainder, width)
      col = rem(remainder, width)
      {row, col}
    end
  end

  defp maybe_trim_top(segments, cursor_index, max_rows) do
    count = length(segments)

    if count <= max_rows do
      {segments, cursor_index, true}
    else
      drop = count - max_rows
      {Enum.drop(segments, drop), max(cursor_index - drop, 0), false}
    end
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

  defp eol, do: ["\e[K", "\r\n"]
end
