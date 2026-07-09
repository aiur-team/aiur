defmodule Aiur.PaneManager.ScreenGrabTest do
  use ExUnit.Case, async: false

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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
