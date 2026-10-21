defmodule Aiur.BuildOrder.IndexSupervisionTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport
  import Aiur.TestSupport.BuildHome.IndexParts, only: [parts: 0]

  test "index is last after every interactive child and absent without dashboard" do
    modules = modules(build_index?: true)
    assert List.last(modules) == AiurWeb.Build.IndexSupervisor
    assert Aiur.Tmux in modules
    without = Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: false, build_index?: true)
    refute Enum.any?(without, &(&1 in [AiurWeb.Build.Index, AiurWeb.Build.IndexSupervisor]))
  end

  # A shared index reread `now` on another test's bus signal and logged read_failed into SignalTest's capture_log (#5164).
  test "the test VM runs no shared index for other tests' signals to wake" do
    refute AiurWeb.Build.IndexSupervisor in modules([])
    refute Process.whereis(AiurWeb.Build.Index)
  end

  test "repeated index crashes do not stop the application supervisor" do
    entry = List.last(Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true, build_index?: true))
    parent = self()

    opts = [
      name: nil,
      subscribe: fn ->
        send(parent, {:index_started, self()})
        :ok
      end,
      read: fn _, _, _ -> parts() end,
      timer: fn _, _, _ -> make_ref() end,
      daemon_timer: fn _, _, _ -> make_ref() end,
      daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end
    ]

    # The production entry under the application's own supervisor and default restart limits.
    {:ok, top} = Aiur.Application.start_supervisor([{entry, opts}])
    Process.unlink(top)
    on_exit(fn -> if Process.alive?(top), do: Process.exit(top, :kill) end)
    top_ref = Process.monitor(top)

    for _ <- 1..4 do
      receive_barrier({:index_started, index})
      index_ref = Process.monitor(index)
      Process.exit(index, :kill)
      receive_barrier({:DOWN, ^index_ref, :process, ^index, :killed})
    end

    assert is_list(Supervisor.which_children(top))
    refute_received {:DOWN, ^top_ref, :process, ^top, _}
  end

  test "application supervisor restarts the build index supervisor" do
    entry = List.last(Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true, build_index?: true))
    parent = self()

    opts = [
      name: nil,
      subscribe: fn ->
        send(parent, {:index_started, self()})
        :ok
      end,
      read: fn _, _, _ -> parts() end,
      timer: fn _, _, _ -> make_ref() end,
      daemon_timer: fn _, _, _ -> make_ref() end,
      daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end
    ]

    {:ok, top} = Aiur.Application.start_supervisor([{entry, opts}])
    Process.unlink(top)
    on_exit(fn -> if Process.alive?(top), do: Process.exit(top, :kill) end)

    receive_barrier({:index_started, _index})

    [supervisor_pid] =
      for {AiurWeb.Build.IndexSupervisor, pid, :supervisor, _} <- Supervisor.which_children(top), do: pid

    supervisor_ref = Process.monitor(supervisor_pid)
    Process.exit(supervisor_pid, :kill)
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor_pid, :killed}, 2_000
    receive_barrier({:index_started, replacement_index})
    assert Process.alive?(replacement_index)

    assert Enum.any?(Supervisor.which_children(top), fn
             {AiurWeb.Build.IndexSupervisor, pid, :supervisor, _} -> pid != supervisor_pid
             _ -> false
           end)
  end

  defp modules(opts) do
    Aiur.Application.child_specs([interactive_cli?: true, headless?: false, dashboard?: true] ++ opts)
    |> Enum.map(fn
      {module, _} -> module
      module -> module
    end)
  end
end
