defmodule Aiur.PaneManager.LayoutTest do
  use ExUnit.Case, async: true

  alias Aiur.PaneManager.Layout

  describe "checksum/1" do
    test "matches tmux's layout_checksum for a captured real layout" do
      # Captured from `tmux list-windows -F '#{window_layout}'` on tmux 3.5a:
      # `8f06,80x24,0,0{40x24,0,0[40x12,0,0,0,40x11,0,13,2],39x24,41,0,1}`
      body = "80x24,0,0{40x24,0,0[40x12,0,0,0,40x11,0,13,2],39x24,41,0,1}"
      assert Layout.checksum(body) == 0x8F06
    end
  end

  describe "build/5" do
    test "single anchor with no conversation slots renders as one pane" do
      out = Layout.build(80, 24, 3, "%1", [nil, nil, nil, nil, nil])

      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0,1$/
    end

    test "anchor + first slot splits top row in half horizontally" do
      out = Layout.build(80, 24, 3, "%1", ["%10", nil, nil, nil, nil])

      # Two cells in 80 cells of width with 1 divider: 40 + 1 + 39.
      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0\{40x24,0,0,1,39x24,41,0,10\}$/
    end

    test "full max_vertical_panes=3 grid is a 2-row, 3-column layout" do
      out = Layout.build(80, 24, 3, "%1", ["%10", "%11", "%12", "%13", "%14"])

      expected_body =
        "80x24,0,0[" <>
          "80x12,0,0{26x12,0,0,1,26x12,27,0,10,26x12,54,0,11}," <>
          "80x11,0,13{26x11,0,13,12,26x11,27,13,13,26x11,54,13,14}" <>
          "]"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "full max_vertical_panes=4 grid is a 2-row, 4-column layout" do
      # 4 columns of width: (80 - 3 dividers) / 4 = 77/4 = 19 with rem 1
      # → first col 20, others 19. Positions: 0, 21, 41, 61.
      out = Layout.build(80, 24, 4, "%1", ["%10", "%11", "%12", "%13", "%14", "%15", "%16"])

      expected_body =
        "80x24,0,0[" <>
          "80x12,0,0{20x12,0,0,1,19x12,21,0,10,19x12,41,0,11,19x12,61,0,12}," <>
          "80x11,0,13{20x11,0,13,13,19x11,21,13,14,19x11,41,13,15,19x11,61,13,16}" <>
          "]"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "missing top-row slot collapses to remaining alive panes" do
      # max_vertical_panes=3, only agent_list and slot 2 alive in top row,
      # bottom row empty. Top row becomes 2 cells.
      out = Layout.build(80, 24, 3, "%1", [nil, "%11", nil, nil, nil])

      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0\{40x24,0,0,1,39x24,41,0,11\}$/
    end

    test "missing bottom-row slot collapses bottom row to remaining panes" do
      # max_vertical_panes=3, top row full, bottom row only has slot 3 and 5.
      out = Layout.build(80, 24, 3, "%1", ["%10", "%11", "%12", nil, "%14"])

      # Bottom row 2 panes in 80 width → 40 + 1 + 39.
      expected_body =
        "80x24,0,0[" <>
          "80x12,0,0{26x12,0,0,1,26x12,27,0,10,26x12,54,0,11}," <>
          "80x11,0,13{40x11,0,13,12,39x11,41,13,14}" <>
          "]"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "only bottom row populated puts the bottom row at full height" do
      # Anchor + slot 3 only. Top row still has the anchor; bottom row
      # has slot 3. Two rows means split-height applies.
      out = Layout.build(80, 24, 3, "%1", [nil, nil, "%12", nil, nil])

      expected_body =
        "80x24,0,0[" <>
          "80x12,0,0,1," <>
          "80x11,0,13,12" <>
          "]"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "pane ids with multi-digit numeric parts are rendered correctly" do
      out = Layout.build(80, 24, 3, "%100", ["%201", nil, nil, nil, nil])

      assert out =~ ~r/40x24,0,0,100,39x24,41,0,201/
    end
  end

  defp hex4(n) do
    n
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end
end
