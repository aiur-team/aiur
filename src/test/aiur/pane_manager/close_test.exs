defmodule Aiur.PaneManager.CloseTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, Tmux}
  alias Aiur.PaneManager.{Close, State}

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

  describe "close_opencode_or_generic/3" do
    test "kills a generic pane (no slot owner), forgets mapping, replies :ok", %{
      tmux: tmux,
      state: state
    } do
      state = State.record_slot_pane(state, 1, "%10", "issue-1")
      :ok = AgentPubSub.subscribe_status()

      task =
        Task.async(fn ->
          Close.close_opencode_or_generic(state, "issue-1", "%10")
        end)

      receive do
        {:tmux_mock_out, "kill-pane -t %10"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected kill-pane -t %10")
      end

      # layout apply
      receive do
        {:tmux_mock_out, "display-message" <> _} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n100 24\n%end 1 1 0\n"})
      after
        100 -> :ok
      end

      receive do
        {:tmux_mock_out, "select-layout" <> _} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        100 -> :ok
      end

      {:reply, result, new_state} = Task.await(task)

      assert result == :ok
      refute Map.has_key?(new_state.identifier_to_pane, "issue-1")
      assert_receive {:status_changed, %{identifier: "issue-1", status: :pane_closed}}
    end
  end

  describe "hide_slot_pane/3" do
    test "replies {:error, :not_slot_pane} when no slot owns the pane", %{
      tmux: _tmux,
      state: state
    } do
      state = State.record_slot_pane(state, 1, "%10", "issue-1")

      {:reply, result, new_state} = Close.hide_slot_pane(state, "issue-1", "%10")

      assert result == {:error, :not_slot_pane}
      assert new_state == state
    end
  end
end
