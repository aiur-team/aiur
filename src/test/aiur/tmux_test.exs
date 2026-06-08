defmodule Aiur.TmuxTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{server: pid, name: name}
  end

  test "command/2 forwards a line to tmux and returns the parsed response", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :task_started)
        Tmux.command(name, "list-panes")
      end)

    assert_receive :task_started
    assert_receive {:tmux_mock_out, "list-panes"}, 1_000

    # Mock a tmux response framed like the control-mode wire format.
    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%1\n%end 1 1 0\n"})

    assert {:ok, ["%1"]} = Task.await(task, 1_000)
  end

  test "command/2 surfaces error responses", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.command(name, "bogus")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, "bogus"}

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\nfail\n%error 1 1 0\n"})

    assert {:error, ["fail"]} = Task.await(task, 1_000)
  end

  test "session/1 returns the configured session name", %{name: name} do
    assert "test" = Tmux.session(name)
  end

  test "move_pane_hidden/3 issues move-pane -d -h to the hidden target", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_hidden(name, "%42", "_aiur_warm")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -d -s %42 -t _aiur_warm -h"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "move_pane_visible/3 issues move-pane -s -t -h (no -d) to the visible target", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_visible(name, "%42", "agents")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "move-pane -s %42 -t agents -h"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
    assert :ok = Task.await(task, 1_000)
  end

  test "list_panes/2 returns pane ids for a target window", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.list_panes(name, "test:0")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, cmd}, 1_000
    assert cmd == "list-panes -t test:0 -F \#{pane_id}"

    send(GenServer.whereis(name), {:tmux_mock_data, "%begin 1 1 0\n%10\n%11\n%end 1 1 0\n"})

    assert {:ok, ["%10", "%11"]} = Task.await(task, 1_000)
  end

  test "move_pane_hidden/3 surfaces tmux errors as {:error, _}", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        Tmux.move_pane_hidden(name, "%bogus", "_aiur_warm")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(
      GenServer.whereis(name),
      {:tmux_mock_data, "%begin 1 1 0\ncan't find pane: %bogus\n%error 1 1 0\n"}
    )

    assert {:error, _} = Task.await(task, 1_000)
  end
end
