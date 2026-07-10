defmodule Aiur.PaneManager.ScreenGrabTest do
  use ExUnit.Case, async: false

  alias Aiur.{Tmux}
  alias Aiur.PaneManager.{ScreenGrab, State}

  setup do
    previous = System.get_env("AIUR_SCREEN_GRAB")

    on_exit(fn ->
      restore_env("AIUR_SCREEN_GRAB", previous)
    end)

    :ok
  end

  test "screen_grab? reads truthy values" do
    for value <- ["1", "true", " YES "] do
      System.put_env("AIUR_SCREEN_GRAB", value)
      assert ScreenGrab.screen_grab?()
    end
  end

  test "screen_grab? is false for zero or unset" do
    System.put_env("AIUR_SCREEN_GRAB", "0")
    refute ScreenGrab.screen_grab?()

    System.delete_env("AIUR_SCREEN_GRAB")
    refute ScreenGrab.screen_grab?()
  end

  test "dead_tmux? only matches no-server binaries" do
    assert ScreenGrab.dead_tmux?("no server running on /tmp/tmux-1001/default")
    refute ScreenGrab.dead_tmux?("can't find pane")
    refute ScreenGrab.dead_tmux?(:closed)
  end

  test "collect_tracked_panes labels anchor and non-nil slots" do
    state = %State{
      agent_list_pane: "%1",
      slot_panes: %{1 => "%10", 2 => nil, 3 => "%12"},
      pane_to_identifier: %{"%10" => "issue-1"}
    }

    assert ScreenGrab.collect_tracked_panes(state) == %{
             "%1" => "agent_list",
             "%10" => "slot1:issue-1",
             "%12" => "slot3:?"
           }
  end

  test "interval is two seconds" do
    assert ScreenGrab.interval_ms() == 2_000
  end

  describe "log_screen_grab/1" do
    setup do
      test_pid = self()
      tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

      {:ok, _} =
        start_supervised(
          {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
          id: tmux_name
        )

      state = %State{
        tmux: tmux_name,
        agent_list_pane: "%1",
        slot_panes: %{1 => "%10", 2 => nil},
        pane_to_identifier: %{"%10" => "issue-1"}
      }

      %{tmux: tmux_name, state: state}
    end

    test "captures each tracked pane and returns :ok", %{tmux: tmux, state: state} do
      task = Task.async(fn -> ScreenGrab.log_screen_grab(state) end)

      for _i <- 1..2 do
        assert_receive {:tmux_mock_out, "capture-pane -p -t " <> _}, 500
        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\nsome content\n%end 1 1 0\n"})
      end

      assert :ok = Task.await(task, 2000)
    end

    test "logs error when capture-pane fails", %{tmux: tmux, state: state} do
      state = %{state | slot_panes: %{}}
      task = Task.async(fn -> ScreenGrab.log_screen_grab(state) end)

      assert_receive {:tmux_mock_out, "capture-pane -p -t %1"}, 500
      send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%error\ncapture failed\n%end 1 1 0\n"})

      assert :ok = Task.await(task, 2000)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
