defmodule SymphonyElixir.TmuxTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tmux

  setup do
    test_pid = self()
    name = Module.concat(__MODULE__, :"Inst#{System.unique_integer([:positive])}")

    {:ok, pid} =
      start_supervised({Tmux, [transport: {:mock, test_pid}, name: name, session: "test"]})

    %{server: pid, name: name}
  end

  test "command/2 sends a line and returns the parsed response", %{name: name} do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :task_started)
        Tmux.command(name, "list-panes")
      end)

    assert_receive :task_started
    assert_receive {:tmux_mock_out, "list-panes"}, 1_000

    # Simulate tmux replying with %begin .. %end framing.
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

  test "subscribers receive notification events", %{name: name} do
    :ok = Tmux.subscribe_events(name)

    send(GenServer.whereis(name), {:tmux_mock_data, "%pane-died %7\n"})
    assert_receive {:tmux_event, {:notification, :pane_died, "%7"}}, 1_000

    send(
      GenServer.whereis(name),
      {:tmux_mock_data, "%window-pane-changed @1 %8\n"}
    )

    assert_receive {:tmux_event, {:notification, :window_pane_changed, "@1", "%8"}}, 1_000
  end
end
