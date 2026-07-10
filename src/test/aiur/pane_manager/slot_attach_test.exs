defmodule Aiur.PaneManager.SlotAttachTest do
  use ExUnit.Case, async: false

  alias Aiur.PaneManager.{SlotAttach, State}
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

  describe "pane_already_visible_reason?/1" do
    test "returns true when reason string contains the expected tmux message" do
      assert SlotAttach.pane_already_visible_reason?("source and target panes must be different")
    end

    test "returns true when reason is a tuple with the tmux message" do
      assert SlotAttach.pane_already_visible_reason?({1, "source and target panes must be different"})
    end

    test "returns false for unrelated error strings" do
      refute SlotAttach.pane_already_visible_reason?("no such pane")
    end

    test "returns false for non-string reasons" do
      refute SlotAttach.pane_already_visible_reason?(:some_atom)
    end
  end

  describe "reply_or_noreply/3" do
    test "with from=nil returns {:reply, result, state}" do
      state = %State{slot_panes: State.empty_slot_panes(5)}
      assert {:reply, :my_result, ^state} = SlotAttach.reply_or_noreply(:my_result, nil, state)
    end

    test "with a from pid, sends reply and returns {:noreply, state}" do
      state = %State{slot_panes: State.empty_slot_panes(5)}
      test_pid = self()
      reply_ref = make_ref()

      result =
        Task.async(fn ->
          from = {test_pid, reply_ref}
          SlotAttach.reply_or_noreply(:sent_result, from, state)
        end)
        |> Task.await()

      assert {:noreply, ^state} = result
      assert_receive {^reply_ref, :sent_result}
    end
  end

  describe "record_slot_pane/4" do
    test "updates identifier_to_pane in state and issues set-title via tmux", %{
      tmux: tmux,
      state: state
    } do
      task =
        Task.async(fn ->
          SlotAttach.record_slot_pane(state, 1, "%20", "issue-42")
        end)

      receive do
        {:tmux_mock_out, "select-pane -t %20 -T " <> _} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> :ok
      end

      new_state = Task.await(task)
      assert Map.get(new_state.identifier_to_pane, "issue-42") == "%20"
      assert Map.get(new_state.pane_to_identifier, "%20") == "issue-42"
      assert Map.get(new_state.pane_to_slot, "%20") == 1
      assert Map.get(new_state.slot_panes, 1) == "%20"
    end
  end

  describe "attach_identifier_to_slot/5" do
    test "selects, moves, records, and replies for a ready slot", %{tmux: tmux, state: state} do
      {:ok, slot_pid} = start_supervised({Aiur.PaneManager.SlotAttachTest.FakeSlot, {:ok, "%30"}})
      task = Task.async(fn -> SlotAttach.attach_identifier_to_slot(state, "issue-30", 1, slot_pid, nil) end)

      assert_receive {:tmux_mock_out, "move-pane -s %30 -t test:0 -h"}, 500
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      assert_receive {:tmux_mock_out, "select-pane -t %30 -T issue-30"}, 500
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 500
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n80x24\n%end 1 1 0\n"})
      assert_receive {:tmux_mock_out, "select-layout -t test:0 " <> _}, 500
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

      assert {:reply, {:ok, "%30"}, new_state} = Task.await(task)
      assert new_state.identifier_to_pane == %{"issue-30" => "%30"}
    end

    test "returns a slot select error without touching tmux", %{state: state} do
      {:ok, slot_pid} = start_supervised({Aiur.PaneManager.SlotAttachTest.FakeSlot, {:error, :not_ready}})

      assert {:reply, {:error, :not_ready}, ^state} =
               SlotAttach.attach_identifier_to_slot(state, "issue-31", 1, slot_pid, nil)

      refute_receive {:tmux_mock_out, _}, 100
    end
  end

  describe "set_pane_title/3" do
    test "calls select-pane -T on the pane via tmux", %{tmux: tmux, state: state} do
      task =
        Task.async(fn ->
          SlotAttach.set_pane_title(state, "%5", "issue-7")
        end)

      receive do
        {:tmux_mock_out, "select-pane -t %5 -T " <> _} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected select-pane -t %5 -T command for pane title")
      end

      assert :ok = Task.await(task)
    end
  end

  describe "bump_next_slot/0" do
    test "does not crash even when SlotPolicy is unavailable" do
      assert :ok = SlotAttach.bump_next_slot()
    end
  end

  describe "attach_to_focused_pane/3" do
    test "returns {:error, :no_focused_pane} when last_attached_pane_id is nil", %{state: state} do
      state = %{state | last_attached_pane_id: nil}
      from = {self(), make_ref()}

      assert {:reply, {:error, :no_focused_pane}, new_state} =
               SlotAttach.attach_to_focused_pane(state, "issue-1", from)

      assert new_state.last_attached_pane_id == nil
    end

    test "returns {:error, :no_focused_pane} when pane is not tracked in pane_to_slot", %{
      state: state
    } do
      state = %{state | last_attached_pane_id: "%99"}
      from = {self(), make_ref()}

      assert {:reply, {:error, :no_focused_pane}, new_state} =
               SlotAttach.attach_to_focused_pane(state, "issue-1", from)

      assert new_state.last_attached_pane_id == nil
    end
  end
end

defmodule Aiur.PaneManager.SlotAttachTest.FakeSlot do
  use GenServer

  def start_link(reply), do: GenServer.start_link(__MODULE__, reply)
  def init(reply), do: {:ok, reply}
  def handle_call({:select, _identifier}, _from, reply), do: {:reply, reply, reply}
end
