defmodule Aiur.ProgressRetentionTest do
  use ExUnit.Case, async: false

  alias Aiur.{ProgressRetention, TrackerIdentity}

  setup do
    state_dir = Aiur.TestSupport.tmp_root!("progress-retention-test")
    on_exit(fn -> File.rm_rf!(state_dir) end)
    %{state_dir: state_dir}
  end

  test "retains a reading keyed by github identity and serves it from the mirror", %{state_dir: state_dir} do
    server = start_store(state_dir)
    ticket = identity()
    reading = progress(40, ~U[2026-07-15 12:00:01Z], 1)

    assert :ok = ProgressRetention.retain(ticket, reading, server: server)

    retained = ProgressRetention.all(server: server)
    key = TrackerIdentity.github_key(ticket)
    assert %{progress: %{percent: 40}} = Map.fetch!(retained, key)

    # The stored identity round-trips as a joinable identity so every consumer
    # can recompute the same github key and render the reading.
    assert %{identity: %TrackerIdentity{} = stored} = Map.fetch!(retained, key)
    assert TrackerIdentity.joinable?(stored)
    assert TrackerIdentity.github_key(stored) == key
  end

  test "is latest-order-wins and ignores an older cast", %{state_dir: state_dir} do
    server = start_store(state_dir)
    ticket = identity()
    observed_at = ~U[2026-07-15 12:00:00Z]

    assert :ok = ProgressRetention.retain(ticket, progress(40, observed_at, 1), server: server)
    assert :ok = ProgressRetention.retain(ticket, progress(70, DateTime.add(observed_at, 5, :second), 2), server: server)
    # An older observation re-cast after the newer one must not roll back.
    assert :ok = ProgressRetention.retain(ticket, progress(10, observed_at, 1), server: server)

    retained = ProgressRetention.all(server: server)
    assert %{progress: %{percent: 70}} = Map.fetch!(retained, TrackerIdentity.github_key(ticket))
  end

  test "persists the checkpoint and reloads it on a fresh store instance", %{state_dir: state_dir} do
    server = start_store(state_dir)
    ticket = identity()
    observed_at = ~U[2026-07-15 12:00:01Z]

    assert :ok = ProgressRetention.retain(ticket, progress(55, observed_at, 1), server: server)
    assert :ok = ProgressRetention.flush(server: server)
    Aiur.TestSupport.safe_stop(server)

    # A brand new instance (daemon restart) reloads the durable reading.
    {:ok, restarted} = ProgressRetention.start_link(name: nil, state_dir: state_dir)
    on_exit(fn -> Aiur.TestSupport.safe_stop(restarted) end)

    retained = ProgressRetention.all(server: restarted)

    assert %{progress: %{percent: 55, observed_at: ^observed_at}} =
             Map.fetch!(retained, TrackerIdentity.github_key(ticket))
  end

  test "terminate flushes without an explicit flush call", %{state_dir: state_dir} do
    server = start_store(state_dir)
    ticket = identity()
    observed_at = ~U[2026-07-15 12:00:02Z]

    assert :ok = ProgressRetention.retain(ticket, progress(65, observed_at, 1), server: server)
    # No flush: the graceful stop runs terminate's final write.
    Aiur.TestSupport.safe_stop(server)

    {:ok, restarted} = ProgressRetention.start_link(name: nil, state_dir: state_dir)
    on_exit(fn -> Aiur.TestSupport.safe_stop(restarted) end)

    retained = ProgressRetention.all(server: restarted)
    assert %{progress: %{percent: 65}} = Map.fetch!(retained, TrackerIdentity.github_key(ticket))
  end

  test "recovers from a corrupt checkpoint into degraded empty state", %{state_dir: state_dir} do
    checkpoint = Path.join(state_dir, "checkpoint.json")
    File.mkdir_p!(state_dir)
    File.write!(checkpoint, "this is not json")

    {:ok, server} = ProgressRetention.start_link(name: nil, state_dir: state_dir)
    on_exit(fn -> Aiur.TestSupport.safe_stop(server) end)

    assert {:degraded, {:checkpoint_corrupt, _reason}} = ProgressRetention.health(server)
    assert ProgressRetention.all(server: server) == %{}

    # The corrupt file is quarantined away so the next boot is healthy and empty.
    assert Enum.any?(File.ls!(state_dir), &String.starts_with?(&1, "checkpoint.json.corrupt-"))
  end

  test "all/1 returns empty when the store is not running" do
    assert ProgressRetention.all(server: :progress_retention_never_started) == %{}
  end

  defp start_store(state_dir) do
    {:ok, server} = ProgressRetention.start_link(name: nil, state_dir: state_dir)
    on_exit(fn -> Aiur.TestSupport.safe_stop(server) end)
    server
  end

  defp identity do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "I-42",
      identifier: "42",
      reason: nil
    }
  end

  defp progress(percent, observed_at, event_id) do
    %{
      percent: percent,
      source: :phase,
      provenance: %{run_id: "run-1", attempt: 1},
      occurred_at: observed_at,
      observed_at: observed_at,
      event_id: event_id,
      order: {DateTime.to_unix(observed_at, :microsecond), event_id}
    }
  end
end
