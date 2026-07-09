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

  test "publish_control_url returns ok when dashboard is unbound" do
    assert Anchor.publish_control_url(:unused) == :ok
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
