defmodule Aiur.PaneManager.PlaceholderTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.PaneManager.{Placeholder, State}
  alias Aiur.Tmux

  setup do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid, :infinity}, name: tmux_name, session: "test"]},
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

  defp receive_command_and_respond(tmux, body \\ "") do
    receive_barrier({:tmux_mock_out, command})
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
    command
  end

  describe "handle_swap/5" do
    test "swaps real pane into placeholder spot, kills placeholder, replies {:noreply, state}", %{
      tmux: tmux,
      state: state
    } do
      state = State.record_placeholder(state, "issue-1", "%99", 1)

      task =
        Task.async(fn ->
          Placeholder.handle_swap(state, "issue-1", "%99", 1, "%20")
        end)

      assert receive_command_and_respond(tmux) == "swap-pane -s %20 -t %99"
      assert receive_command_and_respond(tmux) == "kill-pane -t %99"
      assert receive_command_and_respond(tmux) == "select-pane -t %20"

      # set-pane-title for record_slot_pane
      receive_command_and_respond(tmux)

      # display-message + select-layout for Layout.apply
      receive_command_and_respond(tmux, "80x24\n")
      receive_command_and_respond(tmux)

      # capture-pane for detect_convo_first_paint (async task)
      receive_command_and_respond(tmux)

      {:noreply, new_state} = Task.await(task, :infinity)
      assert Map.get(new_state.identifier_to_pane, "issue-1") == "%20"
      refute Map.has_key?(new_state.placeholder_panes, "issue-1")
    end
  end

  describe "open_with_placeholder/3" do
    test "spawns placeholder pane, stores in state, and replies to caller", %{
      tmux: tmux,
      state: state
    } do
      reply_ref = make_ref()
      from = {self(), reply_ref}
      task = Task.async(fn -> Placeholder.open_with_placeholder(state, "issue-3", from) end)

      assert "split-window -t %1 -h -l 50% " <> command =
               receive_command_and_respond(tmux, "%30\n")

      assert command =~ "issue-3"

      assert receive_command_and_respond(tmux) == "select-pane -t %30"
      assert receive_command_and_respond(tmux) == "select-pane -t %30 -T issue-3"
      assert "display-message -p -t %1 " <> _ = receive_command_and_respond(tmux, "80x24\n")
      assert "select-layout -t test:0 " <> _ = receive_command_and_respond(tmux)

      receive_barrier({^reply_ref, {:ok, "%30"}})
      assert {:noreply, new_state} = Task.await(task, :infinity)
      assert Map.get(new_state.placeholder_panes, "issue-3") == %{pane_id: "%30", slot: 1}
    end

    test "strips single quotes from identifier in split command", %{tmux: tmux, state: state} do
      reply_ref = make_ref()
      from = {self(), reply_ref}
      task = Task.async(fn -> Placeholder.open_with_placeholder(state, "issue-it's-3", from) end)

      assert "split-window -t %1 -h -l 50% " <> command =
               receive_command_and_respond(tmux, "%31\n")

      assert command =~ "issue-its-3"
      refute command =~ "issue-it's-3"

      receive_command_and_respond(tmux)
      receive_command_and_respond(tmux)
      receive_command_and_respond(tmux, "80x24\n")
      receive_command_and_respond(tmux)

      receive_barrier({^reply_ref, {:ok, "%31"}})
      Task.await(task, :infinity)
    end

    test "uses vertical split when state orientation is :vertical", %{tmux: tmux, state: state} do
      reply_ref = make_ref()
      from = {self(), reply_ref}
      state = %{state | orientation: :vertical}
      task = Task.async(fn -> Placeholder.open_with_placeholder(state, "issue-4", from) end)

      assert "split-window -t %1 -v -l 50% " <> _command =
               receive_command_and_respond(tmux, "%32\n")

      receive_command_and_respond(tmux)
      receive_command_and_respond(tmux)
      receive_command_and_respond(tmux, "80x24\n")
      receive_command_and_respond(tmux)

      receive_barrier({^reply_ref, {:ok, "%32"}})
      Task.await(task, :infinity)
    end
  end

  describe "handle_failed/4" do
    test "kills the placeholder pane and drops it from state", %{tmux: tmux, state: state} do
      state = State.record_placeholder(state, "issue-2", "%88", 2)

      task =
        Task.async(fn ->
          Placeholder.handle_failed(state, "issue-2", "%88", :no_ready_slot)
        end)

      assert receive_command_and_respond(tmux) == "kill-pane -t %88"

      # Layout.apply
      receive_command_and_respond(tmux, "80x24\n")
      receive_command_and_respond(tmux)

      {:noreply, new_state} = Task.await(task, :infinity)
      refute Map.has_key?(new_state.placeholder_panes, "issue-2")
    end
  end
end
