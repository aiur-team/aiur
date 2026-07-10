defmodule Aiur.Tmux.QueryTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.Query

  defp mock_state(parent), do: %{transport: {:mock, parent}, session: "test"}

  test "capture_pane/2 returns injected lines" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.capture_pane(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "capture-pane -p -t %42"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nline one\n❯\n%end 1 1 0\n"})
    assert {:ok, ["line one", "❯"]} = Task.await(task, 1_000)
  end

  test "pane_pid/2 parses integer pid" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.pane_pid(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "display-message -p -t %42 \#{pane_pid}"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n12345\n%end 1 1 0\n"})
    assert {:ok, 12_345} = Task.await(task, 1_000)
  end

  test "pane_pid/2 returns {:error, :no_pane_pid} on empty response" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.pane_pid(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert {:error, :no_pane_pid} = Task.await(task, 1_000)
  end

  test "pane_pid/2 returns {:error, :no_pane_pid} on non-integer response" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.pane_pid(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nnot-a-number\n%end 1 1 0\n"})
    assert {:error, :no_pane_pid} = Task.await(task, 1_000)
  end

  test "list_windows/1 tab-splits name/pane lines and drops malformed lines" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.list_windows(state)
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-windows -a -F \#{window_name}\t\#{pane_id}"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\naiur-repl-1\t%1\nbad-line\naiur-repl-2\t%2\n%end 1 1 0\n"})

    assert {:ok, [{"aiur-repl-1", "%1"}, {"aiur-repl-2", "%2"}]} = Task.await(task, 1_000)
  end

  test "list_panes/2 trims and returns pane ids" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.list_panes(state, "test:0")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-panes -t test:0 -F \#{pane_id}"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%10\n%11\n%end 1 1 0\n"})
    assert {:ok, ["%10", "%11"]} = Task.await(task, 1_000)
  end

  test "window_size/2 parses WxH dimensions" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.window_size(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n200x50\n%end 1 1 0\n"})
    assert {:ok, {200, 50}} = Task.await(task, 1_000)
  end

  test "window_size/2 returns {:error, {:bad_dims, _}} on garbage" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.window_size(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nnot-dims\n%end 1 1 0\n"})
    assert {:error, {:bad_dims, _}} = Task.await(task, 1_000)
  end

  test "window_for/2 returns trimmed session:window-index" do
    parent = self()
    state = mock_state(parent)

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.window_for(state, "%42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\ntest:0\n%end 1 1 0\n"})
    assert {:ok, "test:0"} = Task.await(task, 1_000)
  end

  test "resolve_self_pane/1 returns {:error, :no_tmux_pane_env} when TMUX_PANE unset" do
    parent = self()
    state = mock_state(parent)
    original = System.get_env("TMUX_PANE")

    on_exit(fn ->
      if original, do: System.put_env("TMUX_PANE", original), else: System.delete_env("TMUX_PANE")
    end)

    System.delete_env("TMUX_PANE")

    assert {:error, :no_tmux_pane_env} = Query.resolve_self_pane(state)
  end

  test "resolve_self_pane/1 returns {:ok, pane_id} when TMUX_PANE set and server replies" do
    parent = self()
    state = mock_state(parent)
    original = System.get_env("TMUX_PANE")

    on_exit(fn ->
      if original, do: System.put_env("TMUX_PANE", original), else: System.delete_env("TMUX_PANE")
    end)

    System.put_env("TMUX_PANE", "%5")

    task =
      Task.async(fn ->
        send(parent, :ready)
        Query.resolve_self_pane(state)
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%5\n%end 1 1 0\n"})
    assert {:ok, "%5"} = Task.await(task, 1_000)
  end
end
