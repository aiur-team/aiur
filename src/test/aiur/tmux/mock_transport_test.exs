defmodule Aiur.Tmux.MockTransportTest do
  use ExUnit.Case, async: false

  alias Aiur.Tmux.MockTransport
  import Aiur.TestSupport, only: [receive_barrier: 1]

  test "request/2 emits {:tmux_mock_out, command} to the given pid" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        MockTransport.request(parent, "list-panes")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, "list-panes"}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert {:ok, []} = Task.await(task, 1_000)
  end

  test "request/2 with %begin/%end returns {:ok, body}" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        MockTransport.request(parent, "capture-pane -p -t %42")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nline one\n❯\n%end 1 1 0\n"})

    assert {:ok, ["line one", "❯"]} = Task.await(task, 1_000)
  end

  test "request/2 with %begin/%error returns {:error, body}" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        MockTransport.request(parent, "bogus")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\nfail\n%error 1 1 0\n"})

    assert {:error, ["fail"]} = Task.await(task, 1_000)
  end

  test "request/2 returns {:error, :no_mock_response} when no data within 1s" do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, :ready)
        MockTransport.request(parent, "some-cmd")
      end)

    assert_receive :ready
    assert_receive {:tmux_mock_out, _}, 1_000

    assert {:error, :no_mock_response} = Task.await(task, 2_000)
  end

  test "request/3 can wait for an explicit response without a wall-clock deadline" do
    parent = self()

    task = Task.async(fn -> MockTransport.request(parent, "list-panes", :infinity) end)

    receive_barrier({:tmux_mock_out, "list-panes"})
    send(task.pid, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})

    assert {:ok, []} = Task.await(task, :infinity)
  end
end
