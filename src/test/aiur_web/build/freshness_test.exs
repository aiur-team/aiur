defmodule AiurWeb.Build.FreshnessTest do
  use ExUnit.Case, async: false
  alias Aiur.BuildOrder.ProviderHealth
  alias Aiur.Orchestrator.{SnapshotCache, SnapshotStore}
  alias AiurWeb.Build.Freshness
  @now 1_791_408_000_000
  @time ~U[2026-10-07 21:20:00Z]

  test "daemon preserves state, heartbeat, read time and privacy" do
    for {result, state, heartbeat} <- [
          {{:current, %{}, %{observed_at: DateTime.to_iso8601(@time)}}, "live", @now},
          {{:stale, %{}, %{observed_at: @time, reason: :snapshot_stalled, orchestrator_mailbox_depth: 42}}, "stale", @now},
          {{:stale, %{}, %{observed_at: @time, reason: :snapshot_timeout}}, "stale", @now},
          {{:stale, %{}, %{observed_at: @time, reason: :orchestrator_unavailable}}, "offline", @now},
          {:orchestrator_unavailable, "offline", nil},
          {:snapshot_unpublished, "unknown", nil},
          {:boom, "unknown", nil},
          {{:current, %{}, %{observed_at: "x"}}, "unknown", nil},
          {{:stale, %{}, %{}}, "unknown", nil}
        ] do
      assert Freshness.daemon(result, @now + 100) == %{state: state, heartbeat_at: heartbeat, observed_at: @now + 100}
    end
  end

  test "daemon diff ignores live heartbeats but preserves degraded heartbeat changes" do
    live = %{state: "live", heartbeat_at: 1, observed_at: 2}
    stale = %{live | state: "stale"}
    refute Freshness.push_daemon?(live, %{live | heartbeat_at: 3, observed_at: 4})
    refute Freshness.push_daemon?(stale, %{stale | observed_at: 4})
    assert Freshness.push_daemon?(live, stale)
    assert Freshness.push_daemon?(stale, %{stale | heartbeat_at: 3})
    assert Freshness.push_daemon?(nil, live)
  end

  test "provider health distinguishes incomplete, stale and unavailable generations" do
    for {health, state, reason} <- [
          {ProviderHealth.new(1, :healthy, true, observed_at: @time), "ok", nil},
          {ProviderHealth.new(1, :healthy, false, observed_at: @time), "incomplete", "incomplete"},
          {ProviderHealth.new(:unknown, :healthy, true, observed_at: @time), "incomplete", "incomplete"},
          {ProviderHealth.new(1, :stale, true, observed_at: @time, failure: :timeout), "stale", "timeout"},
          {ProviderHealth.new(1, :stale, true, observed_at: @time), "stale", nil},
          {ProviderHealth.new(1, :unavailable, false, observed_at: @time), "unavailable", "unavailable"},
          {ProviderHealth.new(1, :structurally_invalid, false, observed_at: @time), "unavailable", "structurally_invalid"},
          {ProviderHealth.new(1, :unavailable, false, observed_at: @time, failure: :timeout), "unavailable", "timeout"}
        ] do
      assert Freshness.source(health) == %{state: state, observed_at: @now, reason: reason}
    end
  end

  test "snapshot, disabled and unknown sources keep reasons and nullable timestamps" do
    for {input, state, observed_at, reason} <- [
          {{:current, %{}, %{observed_at: DateTime.to_iso8601(@time)}}, "ok", @now, nil},
          {{:stale, %{}, %{observed_at: @time, reason: :snapshot_stalled}}, "stale", @now, "snapshot_stalled"},
          {{:stale, %{}, %{observed_at: "invalid", reason: nil}}, "stale", nil, nil},
          {:snapshot_unpublished, "unavailable", nil, "snapshot_unpublished"},
          {:orchestrator_unavailable, "unavailable", nil, "orchestrator_unavailable"},
          {{:disabled, :no_queue}, "disabled", nil, "no_queue"},
          {:boom, "unavailable", nil, "unknown"}
        ] do
      assert Freshness.source(input) == %{state: state, observed_at: observed_at, reason: reason}
    end
  end

  test "reader uses real cached freshness without calling the stub mailbox" do
    name = :"build_freshness_#{System.unique_integer([:positive])}"
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    Process.register(pid, name)
    SnapshotStore.begin_generation(name)

    on_exit(fn ->
      SnapshotStore.discard(name)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert Freshness.read_daemon(orchestrator: name, timeout: 1_000).state == "unknown"
    SnapshotStore.publish(name, %{})
    live = Freshness.read_daemon(orchestrator: name, timeout: 1_000)
    assert live.state == "live"
    assert abs(live.heartbeat_at - System.os_time(:millisecond)) < 1_000
    assert live.observed_at >= live.heartbeat_at
    cached = SnapshotCache.get(name)
    SnapshotCache.put(name, %{cached | observed_at_ms: System.monotonic_time(:millisecond) - 3_600_000, observed_at: DateTime.add(DateTime.utc_now(), -3_600_000, :millisecond), recent_gaps_ms: []})
    stale = Freshness.read_daemon(orchestrator: name, timeout: 1_000)
    assert stale.state == "stale"
    assert abs(stale.heartbeat_at - (System.os_time(:millisecond) - 3_600_000)) < 1_000
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^pid, :killed} -> :ok)
    assert Freshness.read_daemon(orchestrator: name, timeout: 1_000).state == "offline"
    SnapshotStore.discard(name)
    offline = Freshness.read_daemon(orchestrator: name, timeout: 1_000)
    assert offline.state == "offline"
    assert offline.heartbeat_at == nil
  end
end
