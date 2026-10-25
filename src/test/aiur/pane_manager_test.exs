defmodule Aiur.PaneManagerTest do
  use ExUnit.Case, async: true

  import Aiur.PaneManagerTestSupport

  alias Aiur.{AgentPubSub, PaneManager, Tmux}

  setup do
    start_pane_manager(3)
  end

  test "two unnamed instances start independently" do
    {:ok, first_tmux} =
      start_supervised({Tmux, [transport: {:mock, self()}, session: "first"]}, id: :first_unnamed_tmux)

    {:ok, second_tmux} =
      start_supervised({Tmux, [transport: {:mock, self()}, session: "second"]}, id: :second_unnamed_tmux)

    {:ok, first} =
      start_supervised(
        {PaneManager, [tmux: first_tmux, agent_list_pane: "%1", window_target: "first:0", slot_count: 1]},
        id: :first_unnamed_pane_manager
      )

    {:ok, second} =
      start_supervised(
        {PaneManager, [tmux: second_tmux, agent_list_pane: "%1", window_target: "second:0", slot_count: 1]},
        id: :second_unnamed_pane_manager
      )

    assert first != second
  end

  test "first open splits the agent-list pane and applies layout", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    open_in_slot(pm, tmux, "MT-1", "%10")

    assert_receive {:status_changed, %{identifier: "MT-1", status: :pane_opened}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{"MT-1" => "%10"}
  end

  test ~s(open sets the pane title to "<id> <issue title>"), %{tmux: tmux, pm: pm} do
    task =
      Task.async(fn ->
        PaneManager.open_conversation(pm, "7", "echo 7", title: "CLI: ENS namespace (resolve, reverse, info)")
      end)

    drain_reconcile_if_requested(tmux, ["%1"])
    respond_split(tmux, "%10")
    drain_focus(tmux, "%10")

    title_cmd =
      receive do
        {:tmux_mock_out, "select-pane -t " <> _ = cmd} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 7 0\n%end 1 7 0\n"})
          cmd
      after
        1_000 -> flunk("expected select-pane -T title set")
      end

    assert title_cmd ==
             "select-pane -t %10 -T 7 CLI: ENS namespace (resolve, reverse, info)"

    drain_layout_apply(tmux)
    assert {:ok, "%10"} = Task.await(task, 1_000)
  end

  test "a title with newlines/control chars is scrubbed to a single line", %{tmux: tmux, pm: pm} do
    task =
      Task.async(fn ->
        PaneManager.open_conversation(pm, "7", "echo 7", title: "Line one\nLine two\tend")
      end)

    drain_reconcile_if_requested(tmux, ["%1"])
    respond_split(tmux, "%10")
    drain_focus(tmux, "%10")

    title_cmd =
      receive do
        {:tmux_mock_out, "select-pane -t " <> _ = cmd} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 7 0\n%end 1 7 0\n"})
          cmd
      after
        1_000 -> flunk("expected select-pane -T title set")
      end

    # The single-line pane border must not receive a raw newline/tab.
    assert title_cmd == "select-pane -t %10 -T 7 Line one Line two end"

    drain_layout_apply(tmux)
    assert {:ok, "%10"} = Task.await(task, 1_000)
  end

  test "five opens populate five distinct slots", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")
    open_in_slot(pm, tmux, "MT-3", "%12")
    open_in_slot(pm, tmux, "MT-4", "%13")
    open_in_slot(pm, tmux, "MT-5", "%14")

    assert PaneManager.list_open_panes(pm) == %{
             "MT-1" => "%10",
             "MT-2" => "%11",
             "MT-3" => "%12",
             "MT-4" => "%13",
             "MT-5" => "%14"
           }
  end

  test "sixth open replaces slot 1 via respawn-pane", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")
    open_in_slot(pm, tmux, "MT-3", "%12")
    open_in_slot(pm, tmux, "MT-4", "%13")
    open_in_slot(pm, tmux, "MT-5", "%14")

    # Cycle wraps; the next open targets slot 1, which already holds
    # %10. The implementation replaces the running command via
    # respawn-pane and reuses the same pane id.
    open_via_respawn(pm, tmux, "MT-6", "%10")

    panes = PaneManager.list_open_panes(pm)
    assert Map.get(panes, "MT-6") == "%10"
    refute Map.has_key?(panes, "MT-1")
  end

  test "swapping a slot to a different agent re-titles the pane to the new agent",
       %{tmux: tmux, pm: pm} do
    # Fill all five slots, titling slot 1 with MT-1's issue title.
    open_in_slot_with_title(pm, tmux, "MT-1", "%10", "Original issue")
    open_in_slot(pm, tmux, "MT-2", "%11")
    open_in_slot(pm, tmux, "MT-3", "%12")
    open_in_slot(pm, tmux, "MT-4", "%13")
    open_in_slot(pm, tmux, "MT-5", "%14")

    # The sixth open wraps to slot 1 (%10, held by MT-1) and respawns it for
    # MT-6. The pane title must follow the swap — reflect MT-6, not MT-1.
    title_cmd = open_via_respawn_with_title(pm, tmux, "MT-6", "%10", "Replacement issue")

    assert title_cmd == "select-pane -t %10 -T MT-6 Replacement issue"
  end

  test "close_conversation issues kill-pane, applies layout, frees the slot", %{
    tmux: tmux,
    pm: pm
  } do
    open_in_slot(pm, tmux, "MT-1", "%10")

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-1") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 4 0\n%end 1 4 0\n"})
    drain_layout_apply(tmux)
    assert :ok = Task.await(close_task, 1_000)

    assert PaneManager.list_open_panes(pm) == %{}
  end

  test "hide_by_pane_id reports :not_slot_pane for unknown panes (caller falls back to kill)", %{
    pm: pm
  } do
    assert {:error, :not_slot_pane} = PaneManager.hide_by_pane_id(pm, "%999")
  end

  test "opening the same identifier twice returns the existing pane", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")

    # Second open probes select-pane; the cached pane is still alive
    # so the manager short-circuits and returns it without splitting.
    second = Task.async(fn -> PaneManager.open_conversation(pm, "MT-1", "echo hi") end)
    drain_reconcile_if_requested(tmux, ["%1", "%10"])
    drain_focus(tmux, "%10")
    assert {:ok, "%10"} = Task.await(second, 1_000)
  end

  test "closed slots are not filled until the cycle returns", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-1") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 4 0\n%end 1 4 0\n"})
    drain_layout_apply(tmux)
    assert :ok = Task.await(close_task, 1_000)

    open_in_slot(pm, tmux, "MT-3", "%12")

    assert PaneManager.list_open_panes(pm) == %{"MT-2" => "%11", "MT-3" => "%12"}
  end

  test "closed slot is recreated when the cycle returns to it", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")
    open_in_slot(pm, tmux, "MT-3", "%12")
    open_in_slot(pm, tmux, "MT-4", "%13")
    open_in_slot(pm, tmux, "MT-5", "%14")

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-1") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 4 0\n%end 1 4 0\n"})
    drain_layout_apply(tmux)
    assert :ok = Task.await(close_task, 1_000)

    open_in_slot(pm, tmux, "MT-6", "%15")

    panes = PaneManager.list_open_panes(pm)
    assert Map.get(panes, "MT-6") == "%15"
    refute Map.has_key?(panes, "MT-1")
  end

  test "stale placeholder is reconciled before the next placeholder open", %{tmux: tmux, pm: pm} do
    first_layout = open_placeholder(pm, tmux, "MT-1", "%10", ["%1"])
    assert first_layout =~ ~r/select-layout -t test:0 [0-9a-f]{4},80x24,0,0\{40x24,0,0,1,39x24,41,0,10\}/

    second_layout = open_placeholder(pm, tmux, "MT-2", "%11", ["%1"])

    assert second_layout =~ ~r/select-layout -t test:0 [0-9a-f]{4},80x24,0,0\{40x24,0,0,1,39x24,41,0,11\}/,
           "expected stale placeholder %10 to be dropped before laying out %11, got #{second_layout}"
  end

  test "placeholder open packs visible panes left-to-right (gaps don't strand panes)", %{tmux: tmux, pm: pm} do
    open_placeholder(pm, tmux, "MT-1", "%10", ["%1"])
    open_placeholder(pm, tmux, "MT-2", "%11", ["%1", "%10"])
    open_placeholder(pm, tmux, "MT-3", "%12", ["%1", "%10", "%11"])

    layout = open_placeholder(pm, tmux, "MT-4", "%13", ["%1", "%10", "%12"])

    # After %11 dies and MT-4 replaces it (placeholder reuses freed
    # slot 2), state.slot_panes = {1=%10, 2=%13, 3=%12}. The packed
    # visible list keeps slot-index order: [%10, %13, %12]. With
    # primary_capacity=2 the layout becomes top=[%1, %10, %13],
    # bottom=[%12]. The OLD "slot-index = pane-position" behavior
    # left a single visible pane stranded in the secondary row while
    # the agent list sat alone in primary — the user's "chat opens
    # under the agent list" report. Packing left-to-right keeps the
    # primary row full.
    assert layout =~ "[", "expected a two-row layout after four live panes, got #{layout}"

    # Top row holds agent_list (numeric 1), %10, %13.
    assert layout =~ ~r/\{[^}]*,10,[^}]*,13\}/,
           "expected packed top row to contain %10 and %13, got #{layout}"

    # Bottom row holds the overflow pane (%12).
    assert layout =~ ~r/,12\]/,
           "expected %12 (the overflow pane) in the bottom row, got #{layout}"
  end

  test "four configured columns produce seven slots before cycling" do
    %{tmux: tmux, pm: pm} = start_pane_manager(4)

    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")
    open_in_slot(pm, tmux, "MT-3", "%12")
    open_in_slot(pm, tmux, "MT-4", "%13")
    open_in_slot(pm, tmux, "MT-5", "%14")
    open_in_slot(pm, tmux, "MT-6", "%15")
    open_in_slot(pm, tmux, "MT-7", "%16")

    open_via_respawn(pm, tmux, "MT-8", "%10")

    panes = PaneManager.list_open_panes(pm)
    assert map_size(panes) == 7
    assert Map.get(panes, "MT-8") == "%10"
    refute Map.has_key?(panes, "MT-1")
  end

  test "focused pane dying returns focus to the agent-list pane", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")

    # Attaching marks %10 as the focused pane (last_attached_pane_id).
    attach_task = Task.async(fn -> PaneManager.attach_conversation(pm, "MT-1", "echo hi") end)
    drain_focus(tmux, "%10")
    assert {:ok, "%10"} = Task.await(attach_task, 1_000)

    # The focused pane dies (e.g. user hit Ctrl+C and opencode closed it).
    send(GenServer.whereis(pm), {:tmux_event, {:notification, :pane_died, "%10"}})

    drain_layout_apply(tmux)
    # Focus must snap back to the agent-list pane so j/k/arrows reach it.
    drain_focus(tmux, "%1")
  end

  test "background pane dying does not steal focus", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%10")
    open_in_slot(pm, tmux, "MT-2", "%11")

    # User is focused in %11; %10 is a background pane.
    attach_task = Task.async(fn -> PaneManager.attach_conversation(pm, "MT-2", "echo hi") end)
    drain_focus(tmux, "%11")
    assert {:ok, "%11"} = Task.await(attach_task, 1_000)

    send(GenServer.whereis(pm), {:tmux_event, {:notification, :pane_died, "%10"}})
    drain_layout_apply(tmux)

    # No refocus should fire — the user stays in the pane they were using.
    refute_receive {:tmux_mock_out, "select-pane -t " <> _}, 200
  end

  test "focused pane vanishing via the reconcile poll returns focus to the agent list",
       %{tmux: tmux, pm: pm} do
    # Production never receives the control-mode :pane_died event — it detects a
    # vanished pane through the screen-grab reconcile poll (release_stale_visible_pane).
    # That drop path must refocus the agent list too, otherwise closing an
    # opencode pane leaves j/k/arrows landing in a dead pane (the #16 lockup).
    open_in_slot(pm, tmux, "MT-1", "%10")

    attach_task = Task.async(fn -> PaneManager.attach_conversation(pm, "MT-1", "echo hi") end)
    drain_focus(tmux, "%10")
    assert {:ok, "%10"} = Task.await(attach_task, 1_000)

    # A fresh open triggers the reconcile poll. Report %10 as gone (only %1 is
    # live) so the focused pane is dropped via the production reconcile path.
    open_task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-2", "echo MT-2") end)
    drain_reconcile_if_requested(tmux, ["%1"])
    # The reconcile drop must snap focus back to the agent-list pane.
    drain_focus(tmux, "%1")
    respond_split(tmux, "%11")
    drain_focus(tmux, "%11")
    drain_set_title(tmux, "%11")
    drain_layout_apply(tmux)
    assert {:ok, "%11"} = Task.await(open_task, 1_000)
  end

  test "toggle_orientation flips state and re-applies the layout", %{tmux: tmux, pm: pm} do
    assert PaneManager.orientation(pm) == :horizontal

    toggle_task = Task.async(fn -> PaneManager.toggle_orientation(pm) end)
    drain_layout_apply(tmux)
    assert {:ok, :vertical} = Task.await(toggle_task, 1_000)
    assert PaneManager.orientation(pm) == :vertical

    flip_back = Task.async(fn -> PaneManager.toggle_orientation(pm) end)
    drain_layout_apply(tmux)
    assert {:ok, :horizontal} = Task.await(flip_back, 1_000)
    assert PaneManager.orientation(pm) == :horizontal
  end
end
