defmodule AiurWeb.Build.IndexEstimatesLiveTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias Aiur.BuildOrder.{Estimates, Index.Parts}
  alias AiurWeb.Build.Index

  test "estimate and poll-state subscriptions update visible rows and capacity" do
    dir = Aiur.TestSupport.tmp_root!("estimate-index")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    store = start_supervised!({Estimates, name: nil, state_dir: dir, repository: "acme/widgets"})
    cap = start_supervised!({Agent, fn -> 4 end})
    parent = self()
    initial = parts() |> put_in([:open, Access.key(:tickets)], [open(5, ["complexity:2"])]) |> put_in([:planned, :rows], [plan_row(5)])
    opts = [estimates_opts: [server: store], capacity_fun: fn -> {:current, %{capacity: %{max: Agent.get(cap, & &1)}}, %{observed_at: now()}} end]

    index =
      start_supervised!(
        {Index,
         name: nil,
         read: fn dirty, previous, _ ->
           selected = if dirty == :all, do: MapSet.new([:estimates, :capacity]), else: MapSet.intersection(dirty, MapSet.new([:estimates, :capacity]))
           Map.merge(if(previous == %{}, do: initial, else: previous), Parts.read(selected, opts))
         end,
         timer: fn pid, message, _ ->
           send(parent, {:flush_ready, pid, message})
           make_ref()
         end,
         broadcast: fn changes -> send(parent, {:indexed, changes}) end,
         daemon_timer: fn _, _, _ -> make_ref() end,
         daemon_read: fn _ -> %{state: "live", heartbeat_at: 1, observed_at: 2} end,
         clock: &now/0}
      )

    assert {:ok, first} = Index.window(index, "Etc/UTC")
    assert hd(first.sections.plan).est == 2
    assert first.capacity.max == 4
    :sys.get_state(index)
    drain_initial()
    assert {:ok, _} = Estimates.put(5, 9, "planner correction", "cli:test", server: store)
    receive_barrier({:flush_ready, ^index, :flush})
    send(index, :flush)
    receive_barrier({:indexed, %{upsert: [updated]}})
    assert updated.override.hours == 9
    assert updated.est == 2
    Agent.update(cap, fn _ -> 8 end)
    :ok = Aiur.AgentPubSub.broadcast_poll_state(%{checking?: false, next_poll_due_at_ms: nil, max_concurrent_agents: 8})
    receive_barrier({:flush_ready, ^index, :flush})
    send(index, :flush)
    receive_barrier({:indexed, %{set: %{capacity: capacity}}})
    assert capacity == %{max: 8, observed_at: now(), stale: false}
    assert {:ok, final} = Index.window(index, "Etc/UTC")
    assert final.capacity.max == 8
    assert hd(final.sections.plan).override.hours == 9
    # Snapshot publication can follow the poll signal; its invalidation must refresh capacity too.
    Agent.update(cap, fn _ -> 12 end)
    :ok = Aiur.AgentPubSub.broadcast_fleet_refresh()
    receive_barrier({:flush_ready, ^index, :flush})
    send(index, :flush)
    receive_barrier({:indexed, %{set: %{capacity: published}}})
    assert published.max == 12
  end

  defp drain_initial do
    receive do
      {:indexed, _} -> drain_initial()
    after
      0 -> :ok
    end
  end
end
