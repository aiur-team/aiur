defmodule Aiur.AgentList.Renderer.TextTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentList.Renderer.Text

  test "visual_width scores common terminal-width cases" do
    assert Text.visual_width("abc") == 3
    assert Text.visual_width("🔨") == 2
    assert Text.visual_width("界") == 2
    assert Text.visual_width(<<0xFE0F::utf8>>) == 0
    assert Text.visual_width(<<0x200D::utf8>>) == 0
    assert Text.visual_width([IO.ANSI.red(), "x", IO.ANSI.reset()] |> IO.iodata_to_binary()) == 1
  end

  test "emoji_cell pads empty and wide-leading cells" do
    assert Text.emoji_cell("", 4) == "    "

    cell = Text.emoji_cell("❗9+", 4)
    assert cell == "❗9+"
    assert Text.visual_width(cell) == 4
  end

  test "truncate_visual handles limits and escape boundaries" do
    assert Text.truncate_visual("abc", 0) == ""

    colored = IO.ANSI.red() <> "abc"
    assert Text.truncate_visual(colored, 0) == ""
    assert Text.truncate_visual(colored, 1) == IO.ANSI.red() <> "a"
  end

  test "truncate_visual closes truncated OSC 8 hyperlinks" do
    text = "\e]8;;https://example.test\e\\abcdef\e]8;;\e\\"

    assert Text.truncate_visual(text, 3) ==
             "\e]8;;https://example.test\e\\abc\e]8;;\e\\"
  end

  test "truncate_visual preserves BEL-terminated OSC 8 sequences as zero width" do
    text = "\e]8;;https://example.test\aA\e]8;;\a"

    assert Text.truncate_visual(text, 1) == text
  end

  test "cell collapses whitespace and pads to width" do
    assert Text.cell(" a\n  b\tc ", 8) == "a b c   "
  end

  test "clip_and_pad pads exact fits and truncates over-width text" do
    assert IO.iodata_to_binary(Text.clip_and_pad("abc", 3)) == "abc"
    assert IO.iodata_to_binary(Text.clip_and_pad("abcdef", 4)) == "abc…"
  end

  test "strip helpers distinguish CSI from OSC 8 links" do
    osc = "\e]8;;https://example.test\e\\link\e]8;;\e\\"
    colored = IO.ANSI.red() <> osc <> IO.ANSI.reset()

    assert Text.strip_csi(colored) == osc
    assert Text.strip_ansi(colored) == "link"
  end
end
