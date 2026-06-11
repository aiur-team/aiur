defmodule Aiur.PaneManagerTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, PaneManager, Tmux}

  setup do
    start_pane_manager(3)
  end

  defp start_pane_manager(max_vertical_panes) do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")
    pm_name = Module.concat(__MODULE__, :"PM#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    {:ok, pid} =
      start_supervised(
        {PaneManager,
         [
           tmux: tmux_name,
           name: pm_name,
           agent_list_pane: "%1",
           window_target: "test:0",
           max_vertical_panes: max_vertical_panes,
           # Pin slot_count to the grid formula so round-robin tests
           # see the expected wrap behavior independent of any
           # max_concurrent_agents value from the runtime workflow.
           slot_count: max_vertical_panes * 2 - 1
         ]},
        id: pm_name
      )

    %{server: pid, tmux: tmux_name, pm: pm_name}
  end

  # The new layout-string flow makes the split anchor and percent
  # irrelevant for positioning, so PaneManager always splits the
  # agent-list pane with a default 50/50 horizontal. Tests assert the
  # invariant rather than per-slot recipes.
  defp respond_split(tmux, new_pane_id) do
    receive do
      {:tmux_mock_out, "split-window " <> _ = cmd} ->
        respond_to_split_command(tmux, cmd, new_pane_id)
    after
      1_000 -> flunk("expected split-window")
    end
  end

  defp respond_to_split_command(tmux, cmd, new_pane_id) do
    assert cmd =~ "-t %1", "expected split anchored on agent-list pane, got #{inspect(cmd)}"
    assert cmd =~ ~r/(^|\s)-h(\s|$)/, "expected -h, got #{inspect(cmd)}"
    assert cmd =~ ~r/(^|\s)-l 50%(\s|$)/, "expected -l 50%, got #{inspect(cmd)}"

    send(
      GenServer.whereis(tmux),
      {:tmux_mock_data, "%begin 1 1 0\n#{new_pane_id}\n%end 1 1 0\n"}
    )
  end

  defp drain_reconcile_if_requested(tmux, live_panes) do
    receive do
      {:tmux_mock_out, "list-panes -t test:0 -F \#{pane_id}"} ->
        body = Enum.join(live_panes, "\n")
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}\n%end 1 1 0\n"})
    after
      20 -> :ok
    end
  end

  defp drain_focus(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "select-pane -t " <> rest} ->
        assert String.trim(rest) == pane_id

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 2 0\n%end 1 2 0\n"})
    after
      1_000 -> flunk("expected select-pane focus on #{pane_id}")
    end
  end

  defp respond_respawn(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "respawn-pane " <> rest} ->
        assert rest =~ "-k"
        assert rest =~ "-t #{pane_id}"

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 3 0\n%end 1 3 0\n"})
    after
      1_000 -> flunk("expected respawn-pane for #{pane_id}")
    end
  end

  # After every open, respawn, and close, PaneManager queries window
  # dimensions and applies a layout string. Tests just drain those —
  # the layout-string content is verified in
  # Aiur.PaneManager.LayoutTest, not here.
  defp drain_layout_apply(tmux) do
    receive do
      {:tmux_mock_out, "display-message -p -t %1 " <> _} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 5 0\n80x24\n%end 1 5 0\n"})
    after
      1_000 -> flunk("expected window_size display-message")
    end

    receive do
      {:tmux_mock_out, "select-layout -t test:0 " <> layout} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 6 0\n%end 1 6 0\n"})
        "select-layout -t test:0 " <> layout
    after
      1_000 -> flunk("expected select-layout")
    end
  end

  defp open_in_slot(pm, tmux, identifier, new_pane_id) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "echo " <> identifier) end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_split(tmux, new_pane_id)
    drain_focus(tmux, new_pane_id)
    drain_layout_apply(tmux)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
  end

  defp open_via_respawn(pm, tmux, identifier, pane_id) do
    live_panes = ["%1" | Map.values(PaneManager.list_open_panes(pm))]
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "echo " <> identifier) end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_respawn(tmux, pane_id)
    drain_layout_apply(tmux)
    assert {:ok, ^pane_id} = Task.await(task, 1_000)
  end

  defp open_placeholder(pm, tmux, identifier, new_pane_id, live_panes) do
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "__aiur_opencode__ #{identifier}") end)
    drain_reconcile_if_requested(tmux, live_panes)
    respond_split(tmux, new_pane_id)
    drain_focus(tmux, new_pane_id)
    layout_cmd = drain_layout_apply(tmux)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
    layout_cmd
  end

  test "first open splits the agent-list pane and applies layout", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    open_in_slot(pm, tmux, "MT-1", "%10")

    assert_receive {:status_changed, %{identifier: "MT-1", status: :pane_opened}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{"MT-1" => "%10"}
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
