defmodule Aiur.PaneManagerLiveTest do
  @moduledoc """
  Live-tmux integration test for the conversation pane grid.

  Spawns a real `tmux` server on a per-test temp socket, drives
  `Aiur.PaneManager.open_conversation/3` end-to-end, and asserts the
  resulting pane geometry via `tmux list-panes` — the missing test
  layer that allowed prior regressions of issue #34 to ship with green
  unit tests.

  Skipped when `tmux` is not on `$PATH`, so CI without tmux still
  passes. Run locally with:

      mix test test/aiur/pane_manager_live_test.exs
  """

  use ExUnit.Case, async: false

  alias Aiur.{PaneManager, Tmux}

  @moduletag :live_tmux

  @tmux_skip_reason if(System.find_executable("tmux") == nil,
                      do: "tmux is not on $PATH"
                    )

  @placeholder_cmd "sleep 30"

  setup_all do
    if @tmux_skip_reason do
      :ok
    else
      :ok
    end
  end

  setup tags do
    if @tmux_skip_reason do
      {:ok, tags}
    else
      setup_live_tmux(tags)
    end
  end

  defp setup_live_tmux(_tags) do
    socket = "aiur-pm-live-#{System.unique_integer([:positive])}"
    session = "live"

    on_exit(fn ->
      System.cmd("tmux", ["-L", socket, "kill-server"], stderr_to_stdout: true)
    end)

    # Start a detached session with one pane running a long sleep so
    # the BEAM has a stable anchor pane to play with. `-f /dev/null`
    # so the local user's ~/.tmux.conf doesn't introduce surprise
    # options (base-index, etc.) that drift the window target.
    {output, exit_code} =
      System.cmd(
        "tmux",
        [
          "-L",
          socket,
          "-f",
          "/dev/null",
          "new-session",
          "-d",
          "-s",
          session,
          "-x",
          "200",
          "-y",
          "50",
          "-P",
          "-F",
          "\#{pane_id} \#{session_name}:\#{window_index}",
          @placeholder_cmd
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 0,
           "tmux new-session failed (exit=#{exit_code}): #{String.trim(output)}"

    [anchor_pane, window_target] = output |> String.trim() |> String.split(" ", parts: 2)
    assert anchor_pane != ""
    assert window_target != ""

    # Aiur.Tmux reads AIUR_TMUX_SOCKET from env on every invocation.
    previous_socket_env = System.get_env("AIUR_TMUX_SOCKET")
    System.put_env("AIUR_TMUX_SOCKET", socket)

    on_exit(fn ->
      if previous_socket_env do
        System.put_env("AIUR_TMUX_SOCKET", previous_socket_env)
      else
        System.delete_env("AIUR_TMUX_SOCKET")
      end
    end)

    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")
    pm_name = Module.concat(__MODULE__, :"PM#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [name: tmux_name, session: session]},
        id: tmux_name
      )

    {:ok, _pm} =
      start_supervised(
        {PaneManager,
         [
           tmux: tmux_name,
           name: pm_name,
           agent_list_pane: anchor_pane,
           window_target: window_target,
           max_vertical_panes: 3,
           slot_count: 5
         ]},
        id: pm_name
      )

    %{
      socket: socket,
      session: session,
      anchor_pane: anchor_pane,
      window_target: window_target,
      pm: pm_name
    }
  end

  @tag skip: @tmux_skip_reason
  test "opening 5 conversations builds a 2-row grid with anchor at top-left", %{
    socket: socket,
    window_target: window_target,
    anchor_pane: anchor_pane,
    pm: pm
  } do
    pane_ids =
      for n <- 1..5 do
        {:ok, pane_id} =
          PaneManager.open_conversation(pm, "MT-#{n}", @placeholder_cmd)

        pane_id
      end

    assert length(Enum.uniq(pane_ids)) == 5,
           "expected 5 distinct conversation panes, got #{inspect(pane_ids)}"

    layout = list_panes(socket, window_target)

    # 6 total panes: anchor + 5 conversation slots.
    assert map_size(layout) == 6,
           "expected 6 total panes, got #{map_size(layout)}: #{inspect(layout)}"

    anchor = Map.fetch!(layout, anchor_pane)

    # Anchor sits at the top-left.
    assert anchor.left == 0,
           "expected anchor pane at left=0, got #{anchor.left} (layout=#{inspect(layout)})"

    assert anchor.top == 0,
           "expected anchor pane at top=0, got #{anchor.top} (layout=#{inspect(layout)})"

    # Two rows: the anchor shares its row with at least one conversation
    # pane, and at least one pane sits directly below the anchor (slot 3
    # in the issue's spec).
    same_row_as_anchor =
      layout
      |> Map.values()
      |> Enum.filter(fn p -> p.top == anchor.top end)

    assert match?([_, _ | _], same_row_as_anchor),
           "expected anchor to share its row with at least one conversation pane " <>
             "(layout=#{inspect(layout)})"

    below_anchor =
      layout
      |> Map.values()
      |> Enum.filter(fn p -> p.top > anchor.top and p.left == anchor.left end)

    assert below_anchor != [],
           "expected at least one pane directly below the anchor pane " <>
             "(layout=#{inspect(layout)})"
  end

  @tag skip: @tmux_skip_reason
  test "sixth open reuses the slot-1 pane id (round-robin)", %{pm: pm} do
    pane_ids =
      for n <- 1..5 do
        {:ok, pane_id} =
          PaneManager.open_conversation(pm, "MT-#{n}", @placeholder_cmd)

        pane_id
      end

    {:ok, sixth_pane_id} = PaneManager.open_conversation(pm, "MT-6", "#{@placeholder_cmd}-6")

    assert sixth_pane_id == Enum.at(pane_ids, 0),
           "expected 6th open to reuse slot-1 pane id #{Enum.at(pane_ids, 0)}, got #{sixth_pane_id}"
  end

  @tag skip: @tmux_skip_reason
  test "toggle_orientation round-trips horizontal → vertical → horizontal", %{
    socket: socket,
    window_target: window_target,
    anchor_pane: anchor_pane,
    pm: pm
  } do
    for n <- 1..3 do
      {:ok, _} = PaneManager.open_conversation(pm, "MT-#{n}", @placeholder_cmd)
    end

    horizontal_layout = list_panes(socket, window_target)
    assert PaneManager.orientation(pm) == :horizontal

    # The horizontal layout puts the anchor on the top row sharing space
    # with at least one conversation pane (slot 1 on the right).
    horiz_anchor = Map.fetch!(horizontal_layout, anchor_pane)

    horiz_same_row =
      horizontal_layout
      |> Map.values()
      |> Enum.filter(fn p -> p.top == horiz_anchor.top end)

    assert match?([_, _ | _], horiz_same_row),
           "expected anchor to share its row in horizontal mode " <>
             "(layout=#{inspect(horizontal_layout)})"

    # Flip to vertical: anchor should now share its column with another
    # pane stacked directly below it.
    assert {:ok, :vertical} = PaneManager.toggle_orientation(pm)
    assert PaneManager.orientation(pm) == :vertical

    vertical_layout = list_panes(socket, window_target)
    vert_anchor = Map.fetch!(vertical_layout, anchor_pane)

    below_anchor =
      vertical_layout
      |> Map.values()
      |> Enum.filter(fn p -> p.left == vert_anchor.left and p.top > vert_anchor.top end)

    assert below_anchor != [],
           "expected at least one pane directly below the anchor in vertical mode " <>
             "(layout=#{inspect(vertical_layout)})"

    # Flip back to horizontal: must produce a layout structurally
    # equivalent to the original (anchor at top-left, sharing the top
    # row with conversation panes, no panes below it in the same column
    # until at least one row break).
    assert {:ok, :horizontal} = PaneManager.toggle_orientation(pm)
    assert PaneManager.orientation(pm) == :horizontal

    restored = list_panes(socket, window_target)
    restored_anchor = Map.fetch!(restored, anchor_pane)

    assert restored_anchor.left == 0,
           "expected anchor at left=0 after round-trip, got #{restored_anchor.left} " <>
             "(layout=#{inspect(restored)})"

    assert restored_anchor.top == 0,
           "expected anchor at top=0 after round-trip, got #{restored_anchor.top} " <>
             "(layout=#{inspect(restored)})"

    restored_same_row =
      restored
      |> Map.values()
      |> Enum.filter(fn p -> p.top == restored_anchor.top end)

    assert match?([_, _ | _], restored_same_row),
           "expected anchor to share its row again after toggle back to horizontal " <>
             "(layout=#{inspect(restored)})"
  end

  @tag skip: @tmux_skip_reason
  test "closing a conversation removes its pane", %{
    socket: socket,
    window_target: window_target,
    pm: pm
  } do
    {:ok, _p1} = PaneManager.open_conversation(pm, "MT-1", @placeholder_cmd)
    {:ok, _p2} = PaneManager.open_conversation(pm, "MT-2", @placeholder_cmd)

    assert map_size(list_panes(socket, window_target)) == 3

    :ok = PaneManager.close_conversation(pm, "MT-1")

    wait_until(fn -> map_size(list_panes(socket, window_target)) == 2 end)

    assert map_size(list_panes(socket, window_target)) == 2
  end

  @tag skip: @tmux_skip_reason
  test "external close is reconciled before the next open reflows layout", %{
    socket: socket,
    window_target: window_target,
    pm: pm
  } do
    {:ok, first_pane} = PaneManager.open_conversation(pm, "MT-1", @placeholder_cmd)
    first_layout = list_panes(socket, window_target)
    first_geometry = Map.fetch!(first_layout, first_pane)

    {_output, 0} =
      System.cmd("tmux", ["-L", socket, "kill-pane", "-t", first_pane], stderr_to_stdout: true)

    wait_until(fn -> map_size(list_panes(socket, window_target)) == 1 end)

    {:ok, second_pane} = PaneManager.open_conversation(pm, "MT-2", @placeholder_cmd)
    second_layout = list_panes(socket, window_target)

    assert Map.fetch!(second_layout, second_pane) == first_geometry,
           "expected close-then-open to reuse the same visible chat geometry; " <>
             "first=#{inspect(first_layout)} second=#{inspect(second_layout)}"
  end

  defp list_panes(socket, window_target) do
    {output, 0} =
      System.cmd(
        "tmux",
        [
          "-L",
          socket,
          "list-panes",
          "-t",
          window_target,
          "-F",
          "\#{pane_id} \#{pane_left} \#{pane_top} \#{pane_width} \#{pane_height}"
        ],
        stderr_to_stdout: true
      )

    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [id, l, t, w, h] = String.split(line)

      {id,
       %{
         left: String.to_integer(l),
         top: String.to_integer(t),
         width: String.to_integer(w),
         height: String.to_integer(h)
       }}
    end)
  end

  defp wait_until(check_fn, attempts \\ 50, sleep_ms \\ 20)

  defp wait_until(_check_fn, 0, _sleep_ms), do: :timeout

  defp wait_until(check_fn, attempts, sleep_ms) do
    if check_fn.() do
      :ok
    else
      Process.sleep(sleep_ms)
      wait_until(check_fn, attempts - 1, sleep_ms)
    end
  end
end
