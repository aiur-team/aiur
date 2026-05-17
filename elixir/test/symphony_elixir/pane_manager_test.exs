defmodule SymphonyElixir.PaneManagerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentPubSub, PaneManager, Tmux}

  setup do
    test_pid = self()
    tmux_name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")
    pm_name = Module.concat(__MODULE__, :"PM#{System.unique_integer([:positive])}")

    {:ok, _tmux} =
      start_supervised(
        {Tmux, [transport: {:mock, test_pid}, name: tmux_name, session: "test"]},
        id: tmux_name
      )

    {:ok, pid} =
      start_supervised(
        {PaneManager, [tmux: tmux_name, name: pm_name]},
        id: pm_name
      )

    %{server: pid, tmux: tmux_name, pm: pm_name}
  end

  test "open_conversation records the mapping and broadcasts a status change", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-1", "echo hi") end)

    assert_receive {:tmux_mock_out, "split-window -h -P -F " <> _}, 1_000

    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%99\n%end 1 1 0\n"})

    assert {:ok, "%99"} = Task.await(task, 1_000)
    assert_receive {:status_changed, %{identifier: "MT-PM-1", status: :pane_opened}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{"MT-PM-1" => "%99"}
  end

  test "pane_died notification clears the mapping and broadcasts", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-2", "echo hi") end)
    assert_receive {:tmux_mock_out, _}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%42\n%end 1 1 0\n"})
    assert {:ok, "%42"} = Task.await(task, 1_000)
    assert_receive {:status_changed, %{status: :pane_opened}}, 1_000

    send(GenServer.whereis(tmux), {:tmux_mock_data, "%pane-died %42\n"})

    assert_receive {:status_changed, %{identifier: "MT-PM-2", status: :pane_closed}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{}
  end

  test "close_conversation issues a kill-pane and forgets the mapping", %{tmux: tmux, pm: pm} do
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-3", "echo hi") end)
    assert_receive {:tmux_mock_out, _}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%55\n%end 1 1 0\n"})
    assert {:ok, "%55"} = Task.await(task, 1_000)

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-PM-3") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %55"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 2 0\n%end 1 2 0\n"})
    assert :ok = Task.await(close_task, 1_000)

    assert PaneManager.list_open_panes(pm) == %{}
  end

  test "opening the same identifier twice returns the existing pane", %{tmux: tmux, pm: pm} do
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-4", "echo hi") end)
    assert_receive {:tmux_mock_out, _}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n%77\n%end 1 1 0\n"})
    assert {:ok, "%77"} = Task.await(task, 1_000)

    assert {:ok, "%77"} = PaneManager.open_conversation(pm, "MT-PM-4", "echo hi")
  end
end
