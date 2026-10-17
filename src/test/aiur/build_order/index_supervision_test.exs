defmodule Aiur.BuildOrder.IndexSupervisionTest do
  use ExUnit.Case, async: false
  use Aiur.TestSupport
  import Aiur.TestSupport.BuildHome.IndexParts, only: [parts: 0]

  test "index is last after every interactive child and absent without dashboard" do
    children = Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true)

    modules =
      Enum.map(children, fn
        {module, _} -> module
        module -> module
      end)

    assert List.last(modules) == AiurWeb.Build.IndexSupervisor
    assert Aiur.Tmux in modules
    without = Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: false)
    refute Enum.any?(without, &(&1 in [AiurWeb.Build.Index, AiurWeb.Build.IndexSupervisor]))
  end

  test "repeated index crashes do not stop the application supervisor" do
    entry = List.last(Aiur.Application.child_specs(interactive_cli?: true, headless?: false, dashboard?: true))
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
end
