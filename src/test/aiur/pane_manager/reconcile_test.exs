defmodule Aiur.PaneManager.ReconcileTest do
  use ExUnit.Case, async: false

  alias Aiur.PaneManager.{Reconcile, State}
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
      slot_panes: State.empty_slot_panes(5),
      last_attached_pane_id: nil
    }

    %{tmux: tmux_name, state: state}
  end

  defp respond_ok(tmux) do
    receive do
      {:tmux_mock_out, _cmd} ->
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    after
      500 -> :ok
    end
  end

  describe "refocus_agent_list_if_focused/2" do
    test "emits select-pane and nils last_attached_pane_id when closed pane is focused", %{
      tmux: tmux,
      state: state
    } do
      state = %{state | last_attached_pane_id: "%42"}

      task =
        Task.async(fn ->
          Reconcile.refocus_agent_list_if_focused(state, "%42")
        end)

      receive do
        {:tmux_mock_out, "select-pane -t %1"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
      after
        500 -> flunk("expected select-pane -t %1 for anchor")
      end

      new_state = Task.await(task)
      assert new_state.last_attached_pane_id == nil
    end

    test "is a no-op when closed pane is not the focused pane", %{state: state} do
      state = %{state | last_attached_pane_id: "%42"}
      new_state = Reconcile.refocus_agent_list_if_focused(state, "%99")

      refute_receive {:tmux_mock_out, _}, 100
      assert new_state.last_attached_pane_id == "%42"
    end
  end

  describe "reconcile_visible_panes/1" do
    test "returns state unchanged and issues no tmux command when nothing tracked", %{
      tmux: tmux,
      state: state
    } do
      new_state = Reconcile.reconcile_visible_panes(state)

      refute_receive {:tmux_mock_out, _}, 50
      assert new_state == state
      _ = tmux
    end

    test "returns state unchanged when both pane_to_identifier and placeholder_panes are empty", %{
      state: state
    } do
      state = %{state | pane_to_identifier: %{}, placeholder_panes: %{}}
      new_state = Reconcile.reconcile_visible_panes(state)
      assert new_state == state
    end

    test "drops stale tracked panes not in live window", %{tmux: tmux, state: state} do
      state =
        state
        |> State.record_slot_pane(1, "%10", "issue-1")

      task = Task.async(fn -> Reconcile.reconcile_visible_panes(state) end)

      receive do
        {:tmux_mock_out, "list-panes -t test:0 -F \#{pane_id}"} ->
          send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%1\n%end 1 1 0\n"})
      after
        500 -> flunk("expected list-panes")
      end

      respond_ok(tmux)

      new_state = Task.await(task)
      refute Map.has_key?(new_state.identifier_to_pane, "issue-1")
    end
  end
end
