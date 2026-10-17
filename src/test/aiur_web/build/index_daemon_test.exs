defmodule AiurWeb.Build.IndexDaemonTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  test "daemon ticks bypass the ticket coalescer and only push changes selected by Freshness" do
    topic = "build-home:daemon-test:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    parent = self()
    {:ok, block} = Agent.start_link(fn -> %{state: "live", heartbeat_at: 1, observed_at: 2} end)

    pid =
      start_supervised!(
        {Index,
         name: nil,
         broadcast: fn changes -> Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes}) end,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> parts() end,
         timer: fn _, _, _ -> flunk("daemon must not schedule a ticket flush") end,
         daemon_read: fn _ -> Agent.get(block, & &1) end,
         daemon_timer: fn pid, message, ms ->
           send(parent, {:tick_scheduled, pid, message, ms})
           make_ref()
         end}
      )

    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    :sys.get_state(pid)
    # Mount read is the initial-load barrier; restart and daemon messages may arrive in either order.
    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    drain()
    Agent.update(block, &%{&1 | heartbeat_at: 2, observed_at: 3})
    send(pid, :daemon_tick)
    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    :sys.get_state(pid)
    refute_received {:build_changes, _}
    Agent.update(block, &%{&1 | state: "stale", heartbeat_at: 3})
    send(pid, :daemon_tick)
    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    :sys.get_state(pid)
    assert_received {:build_changes, change}
    assert change.set.daemon == %{state: "stale", heartbeat_at: 3, observed_at: 3}
    assert change.upsert == [] and change.remove == [] and change.resync == false
    Agent.update(block, &%{&1 | heartbeat_at: 4})
    send(pid, :daemon_tick)
    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    :sys.get_state(pid)
    assert_received {:build_changes, %{set: %{daemon: %{heartbeat_at: 4}}}}
    Agent.stop(block)
  end

  defp drain do
    receive do
      {:build_changes, _} -> drain()
    after
      0 -> :ok
    end
  end
end
