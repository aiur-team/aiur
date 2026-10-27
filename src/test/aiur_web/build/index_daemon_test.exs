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
         broadcast: fn changes ->
           Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes})
         end,
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

  test "an unread daemon reading keeps the last good heartbeat so the footer can age it" do
    topic = "build-home:daemon-carry:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    parent = self()
    {:ok, block} = Agent.start_link(fn -> %{state: "live", heartbeat_at: 7, observed_at: 8} end)

    pid =
      start_supervised!(
        {Index,
         name: nil,
         broadcast: fn changes ->
           Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes})
         end,
         subscribe: fn -> :ok end,
         read: fn _, _, _ -> parts() end,
         daemon_read: fn _ -> Agent.get(block, & &1) end,
         daemon_timer: fn pid, message, ms ->
           send(parent, {:tick_scheduled, pid, message, ms})
           make_ref()
         end}
      )

    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    drain()
    Agent.update(block, fn _ -> %{state: "unknown", heartbeat_at: nil, observed_at: 9} end)
    send(pid, :daemon_tick)
    receive_barrier({:tick_scheduled, ^pid, :daemon_tick, 10_000})
    :sys.get_state(pid)

    assert_received {:build_changes, %{set: %{daemon: %{state: "unknown", heartbeat_at: 7, observed_at: 9}}}}

    assert {:ok, %{daemon: %{state: "unknown", heartbeat_at: 7}}} = Index.window(pid, "Etc/UTC")
    Agent.stop(block)
  end

  test "idle build index starts for a LiveView subscriber and stops when the last one leaves" do
    parent = self()
    name = Module.concat(__MODULE__, "Idle#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {Index,
         name: name,
         idle_without_subscribers?: true,
         subscribe: fn ->
           send(parent, :source_subscribed)
           :ok
         end,
         read: fn keys, _, _ ->
           send(parent, {:index_read, keys})
           parts()
         end,
         daemon_read: fn _ ->
           send(parent, :daemon_read)
           %{state: "live", heartbeat_at: 1, observed_at: 2}
         end,
         daemon_timer: fn _, _, _ -> make_ref() end}
      )

    send(pid, {:running_changed, %{}})
    refute_received :source_subscribed
    refute_received {:index_read, _}

    subscriber =
      start_supervised!(
        {Task,
         fn ->
           :ok = Index.subscribe(name)
           send(parent, :subscribed)
           receive(do: (:stop -> :ok))
         end}
      )

    assert_receive :source_subscribed, 1000
    assert_receive :subscribed, 1000
    assert_receive {:index_read, :all}, 1000
    assert_receive :daemon_read, 1000

    monitor_ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^monitor_ref, :process, ^subscriber, :normal}, 1000
    refute :sys.get_state(pid).active?

    send(pid, {:running_changed, %{}})
    send(pid, :daemon_tick)
    refute_receive {:index_read, _}, 100
    refute_received :daemon_read
  end

  defp drain do
    receive do
      {:build_changes, _} -> drain()
    after
      0 -> :ok
    end
  end
end
