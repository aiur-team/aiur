defmodule Aiur.PaneManager.PlaceholderTest do
  use ExUnit.Case, async: false

  alias Aiur.PaneManager.{Placeholder, State}
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

  defp respond_ok(tmux) do
    receive do
      {:tmux_mock_out, _cmd} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    after
      200 -> :ok
    end
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

      # swap-pane
      receive do
        {:tmux_mock_out, "swap-pane -s %20 -t %99"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected swap-pane -s %20 -t %99")
      end

      # kill-pane
      receive do
        {:tmux_mock_out, "kill-pane -t %99"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected kill-pane -t %99")
      end

      # select-pane
      receive do
        {:tmux_mock_out, "select-pane -t %20"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected select-pane -t %20")
      end

      # set-pane-title for record_slot_pane
      respond_ok(tmux)

      # display-message + select-layout for Layout.apply
      respond_ok(tmux)
      respond_ok(tmux)

      # capture-pane for detect_convo_first_paint (async task)
      respond_ok(tmux)

      {:noreply, new_state} = Task.await(task, 5000)
      assert Map.get(new_state.identifier_to_pane, "issue-1") == "%20"
      refute Map.has_key?(new_state.placeholder_panes, "issue-1")
    end
  end

  describe "handle_failed/4" do
    test "kills the placeholder pane and drops it from state", %{tmux: tmux, state: state} do
      state = State.record_placeholder(state, "issue-2", "%88", 2)

      task =
        Task.async(fn ->
          Placeholder.handle_failed(state, "issue-2", "%88", :no_ready_slot)
        end)

      receive do
        {:tmux_mock_out, "kill-pane -t %88"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected kill-pane -t %88")
      end

      # Layout.apply
      respond_ok(tmux)
      respond_ok(tmux)

      {:noreply, new_state} = Task.await(task, 2000)
      refute Map.has_key?(new_state.placeholder_panes, "issue-2")
    end
  end
end
