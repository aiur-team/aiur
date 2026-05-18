defmodule AiurPane.ViewportTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentEvents
  alias AiurPane.{Composer, Viewport}

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
    text = IO.iodata_to_binary(frame) |> visible()
    # Header format: "🟢 MT-VIS" (default work_state circle + id).
    assert text =~ "MT-VIS"
    assert text =~ "🟢"
  end

  test "renders user and agent events with tag prefixes" do
    transcript = [
      AgentEvents.transcript_event(:user, "hi"),
      AgentEvents.transcript_event(:assistant, "hello back")
    ]

    # Each transcript event now produces a tag row + body row(s), and
    # user turns add blank lines above + below, so the default 8-row
    # pane is too tight. Bump rows so both events stay visible.
    {frame, _cursor} = Viewport.render(base_state(transcript: transcript, rows: 16))
    text = IO.iodata_to_binary(frame) |> visible()
    assert text =~ " user "
    assert text =~ "hi"
    assert text =~ " agent "
    assert text =~ "hello back"
  end

  test "wraps alert body text in the terminal-default red SGR" do
    event = AgentEvents.transcript_event(:alert, "task.todo: Task entered todo")
    {frame, _cursor} = Viewport.render(base_state(transcript: [event]))

    raw = IO.iodata_to_binary(frame)
    # `\e[31m` is SGR "default red" — terminals render it from their
    # current palette so it stays readable in both light and dark mode.
    assert raw =~ "\e[31mtask.todo"
    assert raw =~ "task.todo: Task entered todo\e[0m"
  end

  test "wraps command body text in the bright-black SGR for a greyed-out look" do
    event = AgentEvents.transcript_event(:command, "$ ls")
    {frame, _cursor} = Viewport.render(base_state(transcript: [event]))

    raw = IO.iodata_to_binary(frame)
    # `\e[90m` (bright black) is the conventional "muted text" SGR.
    # Every modern terminal renders it as a visibly dimmer variant of
    # the default foreground; `\e[2m` (faint) is unreliable.
    assert raw =~ "\e[90m$ ls"
    assert raw =~ "$ ls\e[0m"
  end

  test "renders diff events as compact update blocks" do
    diff = """
    diff --git a/elixir/lib/example.ex b/elixir/lib/example.ex
    index 1111111..2222222 100644
    --- a/elixir/lib/example.ex
    +++ b/elixir/lib/example.ex
    @@ -108,4 +108,4 @@
     def unchanged
    -  def old_name, do: :old
    +  def new_name, do: :new
     end
    """

    event = AgentEvents.transcript_event(:diff, diff)
    {frame, _cursor} = Viewport.render(base_state(transcript: [event], columns: 90, rows: 20))

    raw = IO.iodata_to_binary(frame)
    text = visible(raw)

    assert text =~ "Update(elixir/lib/example.ex)"
    assert text =~ "Added 1 lines, removed 1 lines"
    assert text =~ "108  def unchanged"
    assert text =~ "109 -  def old_name, do: :old"
    assert text =~ "109 +  def new_name, do: :new"
    assert raw =~ "\e[48;5;52m"
    assert raw =~ "\e[48;5;22m"
  end

  test "renders create and delete diff blocks from multi-file diffs" do
    diff = """
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..1111111
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +one
    +two
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    index 1111111..0000000
    --- a/old.txt
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -gone
    -done
    """

    event = AgentEvents.transcript_event(:diff, diff)
    {frame, _cursor} = Viewport.render(base_state(transcript: [event], columns: 80, rows: 30))
    text = IO.iodata_to_binary(frame) |> visible()

    assert text =~ "Create(new.txt)"
    assert text =~ "Added 2 lines, removed 0 lines"
    assert text =~ "Delete(old.txt)"
    assert text =~ "Added 0 lines, removed 2 lines"
  end

  test "truncates long diff blocks" do
    added_lines =
      1..30
      |> Enum.map_join("\n", fn index -> "+line #{index}" end)

    diff = """
    diff --git a/long.txt b/long.txt
    index 1111111..2222222 100644
    --- a/long.txt
    +++ b/long.txt
    @@ -1,0 +1,30 @@
    #{added_lines}
    """

    event = AgentEvents.transcript_event(:diff, diff)
    {frame, _cursor} = Viewport.render(base_state(transcript: [event], columns: 70, rows: 40))
    text = IO.iodata_to_binary(frame) |> visible()

    assert text =~ "... (6 more lines)"
    assert text =~ "Added 30 lines, removed 0 lines"
  end

  test "diff events do not reset assistant tag coalescing" do
    transcript = [
      AgentEvents.transcript_event(:assistant, "before"),
      AgentEvents.transcript_event(
        :diff,
        """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +b
        """
      ),
      AgentEvents.transcript_event(:assistant, "after")
    ]

    {frame, _cursor} = Viewport.render(base_state(transcript: transcript, columns: 80, rows: 24))
    text = IO.iodata_to_binary(frame) |> visible()

    assert text =~ "before"
    assert text =~ "after"
    assert length(Regex.scan(~r/ agent /, text)) == 1
  end

  test "leaves regular agent text un-styled" do
    event = AgentEvents.transcript_event(:assistant, "hello")
    {frame, _cursor} = Viewport.render(base_state(transcript: [event]))

    raw = IO.iodata_to_binary(frame)
    # The body itself must not be wrapped in a colour SGR — only the
    # tag (which is reset before the body) carries colour. Look at the
    # line tail to confirm no body-styling escape precedes the body.
    refute raw =~ "\e[31mhello"
    refute raw =~ "\e[90mhello"
    assert raw =~ "hello"
  end

  test "right-aligns user tag and left-aligns agent tag" do
    transcript = [
      AgentEvents.transcript_event(:user, "hi"),
      AgentEvents.transcript_event(:assistant, "hello")
    ]

    # 16 rows fits both event blocks (tag row + body row each, plus
    # user-turn padding blanks above/below). At 8 the body_budget
    # truncates the user block off the top.
    {frame, _cursor} = Viewport.render(base_state(transcript: transcript, columns: 40, rows: 16))
    text = IO.iodata_to_binary(frame) |> visible()

    user_row = Enum.find(String.split(text, "\r\n"), fn line -> line =~ " user " end)
    agent_row = Enum.find(String.split(text, "\r\n"), fn line -> line =~ " agent " end)

    # User tag row sits on its own line, right-aligned: leading
    # padding spaces, then the colored tag block.
    assert String.starts_with?(user_row, " ")
    assert String.ends_with?(String.trim_trailing(user_row), "user")

    # Agent tag row sits on its own line, left-aligned. After
    # trim_leading the row begins with "agent " (the leading space of
    # the tag block is consumed by trim_leading).
    assert String.starts_with?(String.trim_leading(agent_row), "agent ")
  end

  test "renders the composer buffer with a > prompt" do
    composer = Composer.append(Composer.new(), "hello")
    {frame, _cursor} = Viewport.render(base_state(composer: composer))
    assert IO.iodata_to_binary(frame) |> visible() =~ "> hello"
  end

  test "places the cursor on the composer input row, after the prompt and buffer" do
    composer = Composer.append(Composer.new(), "hi")
    {_frame, {row, col}} = Viewport.render(base_state(composer: composer, rows: 8))
    # The composer occupies the bottom four rows: gray-blank / tinted
    # input / gray-blank / help. For an 8-row terminal, those are rows
    # 5, 6, 7, 8; the input lives on row 6 (one input row, no wrap).
    assert row == 6
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
    assert text =~ " agent "
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
    # Layout: 24-row pane, 2 input rows + 3 composer chrome rows (top
    # gray blank, bottom gray blank, help row) = 5 composer rows total,
    # so transcript_rows = 19. Row 20 is the top blank, rows 21-22 are
    # the tinted input rows. Cursor lives on segment index 1, so row 22.
    assert row == 22
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
