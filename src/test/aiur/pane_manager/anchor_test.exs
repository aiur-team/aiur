defmodule Aiur.PaneManager.AnchorTest do
  use ExUnit.Case, async: false

  alias Aiur.{PaneManager.Anchor, Tmux}

  setup do
    previous = System.get_env("TMUX_PANE")

    on_exit(fn ->
      restore_env("TMUX_PANE", previous)
    end)

    :ok
  end

  test "opts agent_list_pane wins even when TMUX_PANE is set" do
    System.put_env("TMUX_PANE", "%env")

    assert Anchor.resolve_agent_list_pane([agent_list_pane: "%opt"], :unused) == {:ok, "%opt"}
  end

  test "TMUX_PANE is used when opts are absent" do
    System.put_env("TMUX_PANE", "%env")

    assert Anchor.resolve_agent_list_pane([], :unused) == {:ok, "%env"}
  end

  test "empty TMUX_PANE falls through to tmux self resolution" do
    System.put_env("TMUX_PANE", "")
    tmux = start_tmux()

    assert Anchor.resolve_agent_list_pane([], tmux) == {:error, :no_tmux_pane_env}
  end

  test "resolve_window_target returns opts window_target when non-empty binary" do
    assert Anchor.resolve_window_target([window_target: "session:1"], :unused, "%1") == {:ok, "session:1"}
  end

  test "resolve_window_target falls back to tmux when no opts target" do
    tmux = start_tmux()

    task = Task.async(fn -> Anchor.resolve_window_target([], tmux, "%1") end)

    assert_receive {:tmux_mock_out, "display-message -p -t %1 " <> _}, 500
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\ntest:0\n%end 1 1 0\n"})

    assert {:ok, "test:0"} = Task.await(task, 2000)
  end

  test "publish_control_url writes the supplied URL to the tmux global option" do
    tmux = start_tmux()

    task = Task.async(fn -> Anchor.publish_control_url(tmux, "http://127.0.0.1:4100") end)

    assert_receive {:tmux_mock_out, "set-option -g @aiur_control_url http://127.0.0.1:4100"}, 500
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 2000)
  end

  test "unpublish_control_url removes a stale tmux global option" do
    tmux = start_tmux()

    task = Task.async(fn -> Anchor.unpublish_control_url(tmux) end)

    assert_receive {:tmux_mock_out, "set-option -gu @aiur_control_url"}, 500
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert :ok = Task.await(task, 2000)
  end

  defp start_tmux do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")

    start_supervised!(
      {Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]},
      id: name
    )

    name
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
