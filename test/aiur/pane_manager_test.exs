defmodule Aiur.PaneManagerTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, PaneManager, Tmux}

  setup do
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
        {PaneManager, [tmux: tmux_name, name: pm_name, agent_list_pane: "%1"]},
        id: pm_name
      )

    %{server: pid, tmux: tmux_name, pm: pm_name}
  end

  # Drain the split-window command issued by the open-conversation
  # flow, asserting the target pane and direction match what the
  # given slot expects. Reply with a fresh pane id.
  defp respond_split(tmux, target_pane, direction, pane_id) do
    direction_flag = if direction == :horizontal, do: "-h", else: "-v"

    receive do
      {:tmux_mock_out, "split-window " <> _ = cmd} ->
        assert cmd =~ ~r/-t #{Regex.escape(target_pane)}/,
               "expected split target #{target_pane}, got #{inspect(cmd)}"

        assert cmd =~ ~r/(^|\s)#{direction_flag}(\s|$)/,
               "expected direction flag #{direction_flag}, got #{inspect(cmd)}"

        send(
          GenServer.whereis(tmux),
          {:tmux_mock_data, "%begin 1 1 0\n#{pane_id}\n%end 1 1 0\n"}
        )
    after
      1_000 -> flunk("expected split-window targeting #{target_pane}")
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

  # Drain a respawn-pane command (used when a slot is replaced on a
  # cycle wrap). Replies with empty success.
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

  defp open_in_slot(pm, tmux, identifier, target_pane, direction, new_pane_id) do
    task = Task.async(fn -> PaneManager.open_conversation(pm, identifier, "echo " <> identifier) end)
    respond_split(tmux, target_pane, direction, new_pane_id)
    drain_focus(tmux, new_pane_id)
    assert {:ok, ^new_pane_id} = Task.await(task, 1_000)
  end

  test "first open splits the agent-list pane horizontally into slot 1", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")

    assert_receive {:status_changed, %{identifier: "MT-1", status: :pane_opened}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{"MT-1" => "%10"}
  end

  test "second open splits slot 1 horizontally into slot 2", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")
    open_in_slot(pm, tmux, "MT-2", "%10", :horizontal, "%11")

    assert PaneManager.list_open_panes(pm) == %{"MT-1" => "%10", "MT-2" => "%11"}
  end

  test "third open splits the agent-list pane vertically into slot 3", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")
    open_in_slot(pm, tmux, "MT-2", "%10", :horizontal, "%11")
    open_in_slot(pm, tmux, "MT-3", "%1", :vertical, "%12")

    assert PaneManager.list_open_panes(pm) == %{"MT-1" => "%10", "MT-2" => "%11", "MT-3" => "%12"}
  end

  test "fourth open splits slot 1 vertically into slot 4", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")
    open_in_slot(pm, tmux, "MT-2", "%10", :horizontal, "%11")
    open_in_slot(pm, tmux, "MT-3", "%1", :vertical, "%12")
    open_in_slot(pm, tmux, "MT-4", "%10", :vertical, "%13")
  end

  test "fifth open splits slot 2 vertically into slot 5", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")
    open_in_slot(pm, tmux, "MT-2", "%10", :horizontal, "%11")
    open_in_slot(pm, tmux, "MT-3", "%1", :vertical, "%12")
    open_in_slot(pm, tmux, "MT-4", "%10", :vertical, "%13")
    open_in_slot(pm, tmux, "MT-5", "%11", :vertical, "%14")
  end

  test "sixth open replaces slot 1 via respawn-pane", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")
    open_in_slot(pm, tmux, "MT-2", "%10", :horizontal, "%11")
    open_in_slot(pm, tmux, "MT-3", "%1", :vertical, "%12")
    open_in_slot(pm, tmux, "MT-4", "%10", :vertical, "%13")
    open_in_slot(pm, tmux, "MT-5", "%11", :vertical, "%14")

    # Cycle wraps; the next open targets slot 1, which already holds
    # `%10`. The implementation replaces the running command via
    # `respawn-pane` and reuses the same pane id.
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-6", "echo six") end)
    respond_respawn(tmux, "%10")
    assert {:ok, "%10"} = Task.await(task, 1_000)

    panes = PaneManager.list_open_panes(pm)
    # MT-1's mapping is replaced by MT-6 on the same pane.
    assert Map.get(panes, "MT-6") == "%10"
    refute Map.has_key?(panes, "MT-1")
  end

  test "close_conversation issues kill-pane and frees the slot", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-1") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %10"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 4 0\n%end 1 4 0\n"})
    assert :ok = Task.await(close_task, 1_000)

    assert PaneManager.list_open_panes(pm) == %{}
  end

  test "opening the same identifier twice returns the existing pane", %{tmux: tmux, pm: pm} do
    open_in_slot(pm, tmux, "MT-1", "%1", :horizontal, "%10")

    # Second open probes select-pane; the cached pane is still alive
    # so the manager short-circuits and returns it without splitting.
    second = Task.async(fn -> PaneManager.open_conversation(pm, "MT-1", "echo hi") end)
    drain_focus(tmux, "%10")
    assert {:ok, "%10"} = Task.await(second, 1_000)
  end
end
