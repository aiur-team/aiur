defmodule Aiur.PaneManager.OpencodeOpenTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.SlotRegistry
  alias Aiur.PaneManager.{OpencodeOpen, State}
  alias Aiur.Tmux

  setup do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    state = %State{
      tmux: tmux_name,
      agent_list_pane: "%1",
      window_target: "test:0",
      slot_panes: State.empty_slot_panes(5)
    }

    %{tmux: tmux_name, state: state}
  end

  defp respond(tmux, body \\ "") do
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}\n%end 1 1 0\n"})
  end

  defp drain_layout(tmux) do
    assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 500
    respond(tmux, "80x24")
    assert_receive {:tmux_mock_out, "select-layout -t test:0 " <> _}, 500
    respond(tmux)
  end

  defp drain_focus(tmux, pane_id) do
    assert_receive {:tmux_mock_out, "select-pane -t " <> ^pane_id}, 500
    respond(tmux)
  end

  describe "module public API" do
    test "do_open, open_opencode_pane, and move_warm_pane_visible are exported" do
      exports = OpencodeOpen.__info__(:functions)
      assert {:do_open, 5} in exports
      assert {:open_opencode_pane, 4} in exports
      assert {:move_warm_pane_visible, 5} in exports
    end
  end

  test "do_open routes ordinary commands through the generic split path", %{tmux: tmux, state: state} do
    task = Task.async(fn -> OpencodeOpen.do_open(state, "issue-1", "echo hello", [], nil) end)

    assert_receive {:tmux_mock_out, "split-window " <> command}, 500
    assert command =~ "echo hello"
    respond(tmux, "%10")

    drain_focus(tmux, "%10")
    assert_receive {:tmux_mock_out, "select-pane -t %10 -T issue-1"}, 500
    respond(tmux)
    drain_layout(tmux)

    assert {:reply, {:ok, "%10"}, new_state} = Task.await(task)
    assert new_state.identifier_to_pane == %{"issue-1" => "%10"}
  end

  test "do_open sends an opencode miss to the instant placeholder path", %{tmux: tmux, state: state} do
    reply_ref = make_ref()
    from = {self(), reply_ref}

    task =
      Task.async(fn ->
        OpencodeOpen.do_open(state, "issue-2", "__aiur_opencode__ issue-2", [], from)
      end)

    assert_receive {:tmux_mock_out, "split-window " <> command}, 500
    assert command =~ "Loading opencode for issue-issue-2"
    respond(tmux, "%11")

    drain_focus(tmux, "%11")
    assert_receive {:tmux_mock_out, "select-pane -t %11 -T issue-2"}, 500
    respond(tmux)
    drain_layout(tmux)

    assert_receive {^reply_ref, {:ok, "%11"}}, 500
    assert {:noreply, new_state} = Task.await(task)
    assert new_state.placeholder_panes["issue-2"] == %{pane_id: "%11", slot: 1}
  end

  test "open_opencode_pane promotes the registry-visible warm pane without a placeholder", %{
    tmux: tmux,
    state: state
  } do
    parent = self()
    registered = make_ref()
    slot_index = System.unique_integer([:positive])

    slot_pid =
      spawn(fn ->
        :ok = SlotRegistry.register_self(slot_index)
        :ok = SlotRegistry.update_pane_state(slot_index, "issue-3", "%20")
        send(parent, {registered, :ready})

        receive do
          :exit -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(slot_pid), do: send(slot_pid, :exit)
    end)

    assert_receive {^registered, :ready}, 500

    task = Task.async(fn -> OpencodeOpen.open_opencode_pane(state, "issue-3", [], nil) end)

    assert_receive {:tmux_mock_out, "move-pane -s %20 -t test:0 -h"}, 500
    respond(tmux)
    assert_receive {:tmux_mock_out, "select-pane -t %20 -T issue-3"}, 500
    respond(tmux)
    drain_layout(tmux)

    assert {:reply, {:ok, "%20"}, new_state} = Task.await(task)
    assert new_state.identifier_to_pane == %{"issue-3" => "%20"}

    assert_receive {:tmux_mock_out, "capture-pane -p -t %20"}, 500
    respond(tmux, "Build · issue-3")
  end

  test "move_warm_pane_visible treats an already-visible tmux pane as an open success", %{
    tmux: tmux,
    state: state
  } do
    task = Task.async(fn -> OpencodeOpen.move_warm_pane_visible(state, "issue-4", 2, "%21", nil) end)

    assert_receive {:tmux_mock_out, "move-pane -s %21 -t test:0 -h"}, 500

    send(
      GenServer.whereis(tmux),
      {:tmux_mock_data, "%begin 1 1 0\nsource and target panes must be different\n%error 1 1 0\n"}
    )

    assert_receive {:tmux_mock_out, "select-pane -t %21 -T issue-4"}, 500
    respond(tmux)

    assert {:reply, {:ok, "%21"}, new_state} = Task.await(task)
    assert new_state.identifier_to_pane == %{"issue-4" => "%21"}
    refute_receive {:tmux_mock_out, "display-message" <> _}, 100
  end
end
