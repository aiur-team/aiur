defmodule AiurWeb.Build.IndexResponsiveTest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport.BuildHome.IndexParts
  alias AiurWeb.Build.Index

  setup do
    topic = "build-home:test:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Aiur.PubSub, topic)
    %{topic: topic}
  end

  test "concurrent window calls leave source flushes and daemon updates responsive", %{topic: topic} do
    reads = :counters.new(1, [])
    beats = :counters.new(1, [])
    big = parts(for n <- 1..10_000, do: row(n, %{end: DateTime.add(~U[2026-10-07 12:00:00Z], -div(n, 50) * 86_400)}))

    read = fn _, _, _ ->
      :counters.add(reads, 1, 1)
      if :counters.get(reads, 1) == 1, do: big, else: put_in(big, [:now, :rows], %{"12" => now_row(12)})
    end

    daemon_read = fn _ ->
      :counters.add(beats, 1, 1)
      %{state: "stale", heartbeat_at: :counters.get(beats, 1), observed_at: now()}
    end

    broadcast = fn changes -> Phoenix.PubSub.broadcast(Aiur.PubSub, topic, {:build_changes, changes}) end

    opts = [
      name: nil,
      subscribe: fn -> :ok end,
      broadcast: broadcast,
      read: read,
      daemon_read: daemon_read,
      timer: fn _, _, _ -> make_ref() end,
      daemon_timer: fn _, _, _ -> make_ref() end,
      clock: &now/0
    ]

    pid = start_supervised!({Index, opts}, id: :responsive_index)
    assert {:ok, _} = Index.window(pid, "Etc/UTC")
    assert_receive {:build_changes, %{set: %{daemon: %{heartbeat_at: 1}}}}, 5_000
    drain_changes()
    zones = ~w(Etc/UTC America/Los_Angeles Asia/Tokyo Europe/London)
    # Queue every mount ahead of the daemon tick and source flush.
    :sys.suspend(pid)
    callers = for n <- 1..60, do: Task.async(fn -> Index.window(pid, Enum.at(zones, rem(n, 4)), 30_000) end)
    queued(pid, 60)
    send(pid, :daemon_tick)
    send(pid, {:running_changed, %{}})
    send(pid, :flush)

    {micros, _} =
      :timer.tc(fn ->
        :sys.resume(pid)
        assert_receive {:build_changes, %{set: %{daemon: %{heartbeat_at: 2}}}}, 5_000
      end)

    assert_receive {:build_changes, %{upsert: [%{id: "12"}]}}, 5_000
    assert Enum.all?(Task.await_many(callers, 30_000), &match?({:ok, %{sections: %{hist: [_ | _]}}}, &1))
    # Rescanning all 10,000 rows per mount took ~25 ms each, so 60 mounts delayed the daemon by over a second.
    assert micros < 300_000
  end

  defp queued(pid, count) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len >= count -> :ok
      _ -> queued(pid, count)
    end
  end

  defp drain_changes do
    receive do
      {:build_changes, _} -> drain_changes()
    after
      0 -> :ok
    end
  end
end
