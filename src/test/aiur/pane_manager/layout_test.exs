defmodule Aiur.PaneManager.LayoutTest do
  use ExUnit.Case, async: true

  alias Aiur.{PaneManager.Layout, Tmux}
  alias Aiur.PaneManager.State

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

  describe "build/6 with :vertical orientation" do
    test "single anchor with no conversation slots renders as one pane" do
      out = Layout.build(80, 24, 3, "%1", [nil, nil, nil, nil, nil], :vertical)

      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0,1$/
    end

    test "anchor + first slot stacks the left column in half vertically" do
      out = Layout.build(80, 24, 3, "%1", ["%10", nil, nil, nil, nil], :vertical)

      # Anchor + slot 1 are stacked in a single column spanning full width.
      # Two cells in 24 cells of height with 1 divider: 12 + 1 + 11.
      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0\[80x12,0,0,1,80x11,0,13,10\]$/
    end

    test "full max_vertical_panes=3 grid is a 2-column, 3-row layout" do
      out = Layout.build(80, 24, 3, "%1", ["%10", "%11", "%12", "%13", "%14"], :vertical)

      # Two columns of width: (80 - 1 divider) / 2 = 79/2 = 39, rem 1 →
      # left col 40, right col 39, divider at x=40. Each column stacks
      # three panes vertically: (24 - 2 dividers) / 3 = 22/3 = 7, rem 1 →
      # top pane 8, middle 7, bottom 7. Positions y=0, y=9, y=17.
      expected_body =
        "80x24,0,0{" <>
          "40x24,0,0[40x8,0,0,1,40x7,0,9,10,40x7,0,17,11]," <>
          "39x24,41,0[39x8,41,0,12,39x7,41,9,13,39x7,41,17,14]" <>
          "}"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "missing left-column slot collapses to remaining alive panes" do
      # Anchor + slot 2 alive in left column, secondary column empty.
      # Single column with two panes stacked.
      out = Layout.build(80, 24, 3, "%1", [nil, "%11", nil, nil, nil], :vertical)

      assert out =~ ~r/^[0-9a-f]{4},80x24,0,0\[80x12,0,0,1,80x11,0,13,11\]$/
    end

    test "missing right-column slot collapses right column to remaining panes" do
      # Left column full (anchor + slots 1, 2), right column only has
      # slot 3 (index columns) and slot 5 (last).
      out = Layout.build(80, 24, 3, "%1", ["%10", "%11", "%12", nil, "%14"], :vertical)

      expected_body =
        "80x24,0,0{" <>
          "40x24,0,0[40x8,0,0,1,40x7,0,9,10,40x7,0,17,11]," <>
          "39x24,41,0[39x12,41,0,12,39x11,41,13,14]" <>
          "}"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "only right column populated puts the right column at full width" do
      # Anchor + slot 3 only. Left column has only the anchor; right
      # column has slot 3. Two columns means split-width applies.
      out = Layout.build(80, 24, 3, "%1", [nil, nil, "%12", nil, nil], :vertical)

      expected_body =
        "80x24,0,0{" <>
          "40x24,0,0,1," <>
          "39x24,41,0,12" <>
          "}"

      assert out == "#{hex4(Layout.checksum(expected_body))},#{expected_body}"
    end

    test "pane ids without the leading % render verbatim" do
      # Defensive fallback for the rare future case where Tmux returns
      # an id that doesn't start with `%` (e.g., a numeric tmux global
      # pane id from a non-default format string).
      out = Layout.build(80, 24, 3, "abc", [nil, nil, nil, nil, nil], :vertical)

      assert out =~ ~r/80x24,0,0,abc$/
    end

    test "default orientation is :horizontal (backward compatible)" do
      horizontal = Layout.build(80, 24, 3, "%1", ["%10", nil, nil, nil, nil])
      explicit = Layout.build(80, 24, 3, "%1", ["%10", nil, nil, nil, nil], :horizontal)

      assert horizontal == explicit
    end
  end

  describe "apply/1" do
    test "queries window size and applies the built layout" do
      tmux = start_tmux()

      state = %State{
        tmux: tmux,
        agent_list_pane: "%1",
        window_target: "test:0",
        max_vertical_panes: 3,
        slot_count: 5,
        slot_panes: %{1 => "%10", 2 => nil, 3 => "%12", 4 => nil, 5 => nil},
        orientation: :horizontal
      }

      task = Task.async(fn -> Layout.apply(state) end)

      assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 1_000
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 5 0\n80x24\n%end 1 5 0\n"})

      assert_receive {:tmux_mock_out, "select-layout -t test:0 " <> layout}, 1_000

      assert layout ==
               Layout.build(
                 80,
                 24,
                 3,
                 "%1",
                 State.visible_panes_packed(state),
                 :horizontal
               )

      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 6 0\n%end 1 6 0\n"})
      assert Task.await(task, 1_000) == :ok
    end

    test "returns an error when window size query fails" do
      tmux = start_tmux()

      state = %State{
        tmux: tmux,
        agent_list_pane: "%1",
        window_target: "test:0",
        max_vertical_panes: 3,
        slot_count: 5,
        slot_panes: State.empty_slot_panes(5),
        orientation: :horizontal
      }

      task = Task.async(fn -> Layout.apply(state) end)

      assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 1_000

      send(
        GenServer.whereis(tmux),
        {:tmux_mock_data, "%begin 1 5 0\nwindow missing\n%error 1 5 0\n"}
      )

      assert {:error, _reason} = Task.await(task, 1_000)
    end
  end

  defp hex4(n) do
    n
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
  end

  defp start_tmux do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    start_supervised!(
      {Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]},
      id: name
    )

    name
  end
end
