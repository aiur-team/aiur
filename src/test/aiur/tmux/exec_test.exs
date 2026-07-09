defmodule Aiur.Tmux.ExecTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.Exec

  defp mock_state do
    %{transport: {:mock, self()}, session: "test"}
  end

  test "run_command/2 splits on whitespace and emits the joined string" do
    parent = self()
    state = mock_state()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Exec.run_command(state, "list-panes -t x")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-panes -t x"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert {:ok, []} = Task.await(task, 1_000)
  end

  # FI-TUI-002: split_command/1 parses "hello world" (double-quoted span) as a
  # single argv element. This test exercises the run_args side: given a pre-split
  # list where the quoted span is already one element, the mock transport receives
  # a space-joined string with no outer quotes. split_command itself is called only
  # on :shell transport (System.cmd path) and is not exercised here.
  test "run_args/2 emits pre-split args joined with spaces (FI-TUI-002 run_args side)" do
    parent = self()
    state = mock_state()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Exec.run_args(state, ["send-keys", "-t", "%42", "hello world"])
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "send-keys -t %42 hello world"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert {:ok, []} = Task.await(task, 1_000)
  end

  test "run_args/2 emits Enum.join(args, \" \")" do
    parent = self()
    state = mock_state()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Exec.run_args(state, ["list-panes", "-t", "test:0", "-F", "\#{pane_id}"])
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-panes -t test:0 -F \#{pane_id}"

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%1\n%end 1 1 0\n"})
    assert {:ok, ["%1"]} = Task.await(task, 1_000)
  end

  test "run_args/2 surfaces %error response as {:error, body}" do
    parent = self()
    state = mock_state()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Exec.run_args(state, ["kill-pane", "-t", "%bogus"])
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\ncan't find pane: %bogus\n%error 1 1 0\n"})

    assert {:error, ["can't find pane: %bogus"]} = Task.await(task, 1_000)
  end
end
