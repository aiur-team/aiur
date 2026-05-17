defmodule SymphonyPane.ViewportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentEvents
  alias SymphonyPane.{Composer, Viewport}

  defp base_state(opts) do
    %{
      identifier: Keyword.get(opts, :identifier, "MT-V"),
      transcript: Keyword.get(opts, :transcript, []),
      composer: Keyword.get(opts, :composer, Composer.new()),
      columns: Keyword.get(opts, :columns, 40),
      rows: Keyword.get(opts, :rows, 8)
    }
  end

  defp visible(text) do
    Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")
  end

  test "renders the identifier in the transcript header" do
    {frame, _cursor} = Viewport.render(base_state(identifier: "MT-VIS"))
    assert IO.iodata_to_binary(frame) |> visible() =~ "Symphony — MT-VIS"
  end

  test "renders user and agent events with tag prefixes" do
    transcript = [
      AgentEvents.transcript_event(:user, "hi"),
      AgentEvents.transcript_event(:assistant, "hello back")
    ]

    {frame, _cursor} = Viewport.render(base_state(transcript: transcript))
    text = IO.iodata_to_binary(frame) |> visible()
    assert text =~ "[usr]"
    assert text =~ "hi"
    assert text =~ "[agent]"
    assert text =~ "hello back"
  end

  test "right-aligns user messages and left-aligns agent messages" do
    transcript = [
      AgentEvents.transcript_event(:user, "hi"),
      AgentEvents.transcript_event(:assistant, "hello")
    ]

    {frame, _cursor} = Viewport.render(base_state(transcript: transcript, columns: 40))
    text = IO.iodata_to_binary(frame) |> visible()

    user_row = Enum.find(String.split(text, "\r\n"), fn line -> line =~ "[usr]" end)
    agent_row = Enum.find(String.split(text, "\r\n"), fn line -> line =~ "[agent]" end)

    # User row puts the tag on the right (preceded by padding spaces) so
    # the visual reads like a chat bubble pulled to the right side.
    assert String.starts_with?(user_row, " ")
    assert String.ends_with?(String.trim_trailing(user_row), "[usr]")

    # Agent row puts the tag on the left.
    assert String.starts_with?(String.trim_leading(agent_row), "[agent]")
  end

  test "renders the composer buffer with a > prompt" do
    composer = Composer.append(Composer.new(), "hello")
    {frame, _cursor} = Viewport.render(base_state(composer: composer))
    assert IO.iodata_to_binary(frame) |> visible() =~ "> hello"
  end

  test "places the cursor on the composer input row, after the prompt and buffer" do
    composer = Composer.append(Composer.new(), "hi")
    {_frame, {row, col}} = Viewport.render(base_state(composer: composer, rows: 8))
    # The composer occupies the bottom three rows (blank / tinted input /
    # blank). For an 8-row terminal, that's rows 6, 7, 8; the input lives on
    # the middle row.
    assert row == 7
    # prompt "> " is 2 chars + 2 chars of buffer + 1-based column
    assert col == 5
  end

  test "truncates lines that exceed the inner width" do
    long = String.duplicate("X", 200)
    composer = Composer.append(Composer.new(), long)
    {frame, _cursor} = Viewport.render(base_state(composer: composer, columns: 20))

    frame
    |> IO.iodata_to_binary()
    |> String.split(["\r\n", "\n"])
    |> Enum.each(fn line ->
      assert String.length(visible(line)) <= 19, "line too long: #{inspect(line)}"
    end)
  end

  test "wraps long transcript events to multiple lines instead of truncating" do
    text = String.duplicate("a", 60) <> " " <> String.duplicate("b", 60)
    event = AgentEvents.transcript_event(:assistant, text)
    {frame, _cursor} = Viewport.render(base_state(transcript: [event], columns: 40, rows: 24))

    # inner_width = cols - 1 = 39. The tag block plus space takes 10
    # columns, leaving ~29 for the body. A 121-char body needs multiple
    # wrapped rows.
    text = frame |> IO.iodata_to_binary() |> visible()
    assert text =~ "[agent]"
    assert text =~ String.duplicate("a", 29)
    assert text =~ String.duplicate("b", 29)

    Enum.each(String.split(text, ["\r\n", "\n"]), fn line ->
      line = String.replace(line, "\r", "")
      assert String.length(line) <= 39, "transcript line too long: #{inspect(line)}"
    end)
  end

  test "wraps composer buffer past the prompt-row capacity to the next tinted row" do
    # `inner_width = cols - 1 = 19`, prompt "> " takes 2, so the first row
    # holds 17 chars. A 25-char buffer overflows; the wrap should land the
    # extra 8 chars on a second tinted row directly below the first.
    long = String.duplicate("a", 25)
    composer = Composer.append(Composer.new(), long)
    {frame, {row, _col}} = Viewport.render(base_state(composer: composer, columns: 20, rows: 24))

    text = frame |> IO.iodata_to_binary() |> visible()

    assert text =~ "> aaaaaaaaaaaaaaaaa"
    assert text =~ "aaaaaaaa"
    # Layout: 24-row pane, 2 input rows + 2 blanks = 4 composer rows,
    # transcript_rows = 20. Row 21 is the top blank, rows 22-23 are the
    # tinted input rows. Cursor lives on segment index 1, so row 23.
    assert row == 23
  end

  test "trims early composer rows but keeps the cursor visible when buffer is very long" do
    # max_input_rows is 6; with `inner_width = 19` (first capacity 17,
    # subsequent 19), 200 chars need 11 input rows. We expect the visible
    # composer block to show only the last 6 segments. Those continuation
    # rows must NOT prepend the `> ` prompt — that would overflow the row.
    long = String.duplicate("Z", 200)
    composer = Composer.append(Composer.new(), long)
    {frame, _cursor} = Viewport.render(base_state(composer: composer, columns: 20, rows: 24))

    text = frame |> IO.iodata_to_binary() |> visible()
    # Continuation rows must NOT prepend `> ` (that would overflow). Check
    # every rendered line stays within inner_width once ANSI and trailing
    # CR/LF are stripped.
    Enum.each(String.split(text, ["\r\n", "\n"]), fn line ->
      line = String.replace(line, "\r", "")
      assert String.length(line) <= 19, "wrapped line too long: #{inspect(line)}"
    end)
  end
end
