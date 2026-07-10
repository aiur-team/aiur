defmodule Aiur.Tmux.LayoutTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.Layout

  defp mock_state(parent), do: %{transport: {:mock, parent}, session: "test"}

  test "split_pane/6 non-silent emits split-window then select-pane" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.split_pane(state, "%1", :horizontal, 30, "exec claude", false)
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, split_cmd}, 1_000
    assert split_cmd == "split-window -t %1 -h -l 30% -P -F \#{pane_id} exec claude"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%99\n%end 1 1 0\n"})

    assert_receive {:tmux_mock_out, select_cmd}, 1_000
    assert select_cmd == "select-pane -t %99"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert {:ok, "%99"} = Task.await(task, 1_000)
  end

  test "split_pane/6 with silent: true emits split-window -d and no select-pane" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.split_pane(state, "%1", :horizontal, 30, "exec claude", true)
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "split-window -d -t %1 -h -l 30% -P -F \#{pane_id} exec claude"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%99\n%end 1 1 0\n"})

    assert {:ok, "%99"} = Task.await(task, 1_000)
    refute_receive {:tmux_mock_out, _}, 200
  end

  test "respawn_pane/3 emits respawn-pane -k" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.respawn_pane(state, "%1", "exec claude")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "respawn-pane -k -t %1 exec claude"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "new_hidden_window/3 returns pane id on success" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.new_hidden_window(state, "aiur-repl-1", "exec claude")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "new-window -d -n aiur-repl-1 -P -F \#{pane_id} exec claude"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%5\n%end 1 1 0\n"})
    assert {:ok, "%5"} = Task.await(task, 1_000)
  end

  test "new_hidden_window/3 bootstraps with new-session when no server running" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.new_hidden_window(state, "aiur-repl-1", "exec claude")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, "new-window" <> _}, 1_000

    send(
      task.pid,
      {:tmux_mock_data, "%begin 1 1 0\nno server running on /tmp/tmux-1001/test\n%error 1 1 0\n"}
    )

    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "new-session -d -s test -n aiur-repl-1 -P -F \#{pane_id} exec claude"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%7\n%end 1 1 0\n"})
    assert {:ok, "%7"} = Task.await(task, 1_000)
  end

  test "join_pane/3 emits join-pane -s -t -h" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.join_pane(state, "%42", "agents")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "join-pane -s %42 -t agents -h"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "move_pane_hidden/3 emits move-pane -d -h" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.move_pane_hidden(state, "%42", "_aiur_warm")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -d -s %42 -t _aiur_warm -h"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "move_pane_visible/3 emits move-pane without -d" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.move_pane_visible(state, "%42", "agents")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -s %42 -t agents -h"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "kill_pane/2 returns :ok on success" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.kill_pane(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "kill-pane -t %42"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "kill_pane/2 returns :ok on already-gone pane (idempotent)" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.kill_pane(state, "%gone")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(
      task.pid,
      {:tmux_mock_data, "%begin 1 1 0\ncan't find pane: %gone\n%error 1 1 0\n"}
    )

    assert :ok = Task.await(task, 1_000)
  end

  test "kill_pane/2 returns {:error, _} on other errors" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.kill_pane(state, "%bogus")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nsome other error\n%error 1 1 0\n"})

    assert {:error, _} = Task.await(task, 1_000)
  end

  test "select_layout/3 returns :ok" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Layout.select_layout(state, "test:0", "abc1,200x50,0,0,1")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "select-layout -t test:0 abc1,200x50,0,0,1"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end
end
