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

  defp respond_split(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "split-window " <> _ = cmd} ->
        # The split target should anchor to the rightmost pane so each new
        # conversation opens to the right of the existing rightmost pane.
        assert cmd =~ ~r/-t test:\.\{right\}/,
               "expected split-window to target rightmost pane, got #{inspect(cmd)}"

        send(
          GenServer.whereis(tmux),
          {:tmux_mock_data, "%begin 1 1 0\n#{pane_id}\n%end 1 1 0\n"}
        )
    after
      1_000 -> flunk("expected split-window")
    end
  end

  defp drain_focus(tmux, pane_id) do
    receive do
      {:tmux_mock_out, "select-pane -t " <> rest} ->
        assert String.trim(rest) == pane_id

        send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 2 0\n%end 1 2 0\n"})
    after
      1_000 -> flunk("expected select-pane focus on #{pane_id}")
    end
  end

  test "open_conversation splits right, focuses the new pane, and broadcasts a status change", %{tmux: tmux, pm: pm} do
    :ok = AgentPubSub.subscribe_status()

    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-1", "echo hi") end)

    respond_split(tmux, "%99")
    drain_focus(tmux, "%99")

    assert {:ok, "%99"} = Task.await(task, 1_000)
    assert_receive {:status_changed, %{identifier: "MT-PM-1", status: :pane_opened}}, 1_000
    assert PaneManager.list_open_panes(pm) == %{"MT-PM-1" => "%99"}
  end

  test "close_conversation issues a kill-pane and forgets the mapping", %{tmux: tmux, pm: pm} do
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-3", "echo hi") end)
    respond_split(tmux, "%55")
    drain_focus(tmux, "%55")
    assert {:ok, "%55"} = Task.await(task, 1_000)

    close_task = Task.async(fn -> PaneManager.close_conversation(pm, "MT-PM-3") end)
    assert_receive {:tmux_mock_out, "kill-pane -t %55"}, 1_000
    send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 2 0\n%end 1 2 0\n"})
    assert :ok = Task.await(close_task, 1_000)

    assert PaneManager.list_open_panes(pm) == %{}
  end

  test "opening the same identifier twice returns the existing pane", %{tmux: tmux, pm: pm} do
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-4", "echo hi") end)
    respond_split(tmux, "%77")
    drain_focus(tmux, "%77")
    assert {:ok, "%77"} = Task.await(task, 1_000)

    # Second open probes select-pane to verify the cached pane is still alive
    # before short-circuiting. Respond with an empty ack.
    second = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-4", "echo hi") end)
    drain_focus(tmux, "%77")
    assert {:ok, "%77"} = Task.await(second, 1_000)
  end

  test "respawns a new pane when the cached pane is dead", %{tmux: tmux, pm: pm} do
    task = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-5", "echo hi") end)
    respond_split(tmux, "%88")
    drain_focus(tmux, "%88")
    assert {:ok, "%88"} = Task.await(task, 1_000)

    second = Task.async(fn -> PaneManager.open_conversation(pm, "MT-PM-5", "echo hi") end)

    # The probe select-pane fails — pane has been killed externally.
    receive do
      {:tmux_mock_out, "select-pane -t %88"} ->
        send(
          GenServer.whereis(tmux),
          {:tmux_mock_data, "%begin 1 0 0\ncan't find pane: %88\n%error 1 0 0\n"}
        )
    after
      1_000 -> flunk("expected select-pane probe")
    end

    # PaneManager forgets the dead pane and respawns. New pane id = %99.
    respond_split(tmux, "%99")
    drain_focus(tmux, "%99")

    assert {:ok, "%99"} = Task.await(second, 1_000)
  end
end
