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

  test "renders user and agent events distinctly" do
    transcript = [
      AgentEvents.transcript_event(:user, "hi"),
      AgentEvents.transcript_event(:assistant, "hello back")
    ]

    {frame, _cursor} = Viewport.render(base_state(transcript: transcript))
    text = IO.iodata_to_binary(frame) |> visible()
    assert text =~ "you: hi"
    assert text =~ "agent: hello back"
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
end
