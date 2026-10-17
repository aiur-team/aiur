defmodule Aiur.CurrentRunProjections.ConcurrencyTest do
  use ExUnit.Case, async: true

  import Aiur.CurrentRunProjectionsSupport

  alias Aiur.CurrentRunOutcomeSnapshot
  alias Aiur.CurrentRunProjections
  alias Aiur.CurrentRunProjections.Checkpoint
  alias Aiur.CurrentRunSummary

  test "membership reconciliation freshness transitions projections from partial to exact" do
    {source, owner, _pubsub} =
      start_owner(fn sources ->
        put_in(sources, [:membership, :freshness], %{status: :unknown})
      end)

    :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert summary.health.status == :partial
    assert summary.progress.exact == nil
    assert summary.freshness.status == :unknown
    assert outcomes.state == :partial
    assert outcomes.completeness == :partial

    Agent.update(source, &put_in(&1, [:membership, :freshness], %{status: :fresh}))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert summary.health.status == :healthy
    assert summary.progress.exact == %{numerator: 2, denominator: 5}
    assert outcomes.state == :healthy
    assert outcomes.completeness == :complete
  end

  test "denominator generation changes only at run or weight boundaries" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)
    first = CurrentRunSummary.snapshot(server: owner)
    assert first.denominator.generation == 1

    Agent.update(source, fn sources ->
      put_in(sources, [:activity, :entries], [activity_entry(identity(), 60)])
    end)

    :ok = CurrentRunProjections.refresh(owner)
    progress_only = CurrentRunSummary.snapshot(server: owner)
    assert progress_only.denominator.generation == 1
    assert progress_only.progress.exact == %{numerator: 3, denominator: 5}

    Agent.update(source, fn sources ->
      put_in(sources, [:status_facts, Access.at(0), :complexity], 4)
    end)

    :ok = CurrentRunProjections.refresh(owner)
    reweighted = CurrentRunSummary.snapshot(server: owner)
    assert reweighted.denominator.generation == 2

    Agent.update(source, fn sources ->
      sources
      |> put_in([:run, :id], "run-2")
      |> put_in([:membership, :run_id], "run-2")
    end)

    :ok = CurrentRunProjections.refresh(owner)
    next_run = CurrentRunSummary.snapshot(server: owner)
    assert next_run.run.id == "run-2"
    assert next_run.denominator.generation == 1
    assert next_run.last_known_good == nil
  end

  test "source event bursts coalesce without making the owner unavailable" do
    test_pid = self()

    {source, owner, _pubsub} =
      start_owner(fn value -> value end,
        checkpoint_writer: fn _run_id, _checkpoint ->
          send(test_pid, :projection_checkpoint_written)
          :ok
        end
      )

    :ok = CurrentRunProjections.refresh(owner)
    assert_receive :projection_checkpoint_written, 2_000
    assert Agent.get(source, & &1.run_reads) == 1
    Agent.update(source, &update_in(&1, [:run, :elapsed_ms], fn ms -> ms + 1_000 end))
    :ok = :sys.suspend(owner)
    send(owner, {:ticket_activity_changed, %{}})
    send(owner, {:status_changed, %{}})
    send(owner, {:running_changed, %{}})
    :ok = :sys.resume(owner)

    assert_receive :projection_checkpoint_written, 2_000
    refute_received :projection_checkpoint_written
    assert Agent.get(source, & &1.run_reads) == 2
    assert CurrentRunSummary.health(server: owner).status == :healthy
    assert Process.alive?(owner)
  end

  test "refresh called during an older full refresh waits for a post-call read" do
    {source, owner, _pubsub} = start_owner()
    original_status = Agent.get(source, & &1.status)
    test_pid = self()

    Agent.update(source, &Map.put(&1, :status, {:block, test_pid}))
    first_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    assert_receive {:projection_reader_blocked, :status, status_reader}, 2_000

    # Change the source after the first refresh has already read it. A second
    # synchronous refresh must not join that pre-call read and return stale
    # data; it waits for a follow-up refresh that begins after this call.
    Agent.update(source, &Map.put(&1, :status, :timeout))
    second_refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    assert wait_for_refresh_waiters(owner, 2)
    send(status_reader, {:release_projection_reader, :status, original_status})

    assert Task.await(first_refresh, 2_000) == :ok
    assert Task.await(second_refresh, 2_000) == :ok
    assert :sys.get_state(owner).weight_health == :unavailable
  end

  test "blocked source readers run concurrently while snapshots remain readable" do
    {source, owner, _pubsub} = start_owner(fn value -> value end, source_timeout_ms: 2_500)
    :ok = CurrentRunProjections.refresh(owner)
    baseline = CurrentRunSummary.snapshot(server: owner)
    reader_keys = [:run, :membership, :status, :status_facts, :activity, :merges, :configured_repository]
    test_pid = self()

    Agent.update(source, fn current ->
      Enum.reduce(reader_keys, current, &Map.put(&2, &1, {:block, test_pid}))
    end)

    refresh = Task.async(fn -> CurrentRunProjections.refresh(owner) end)

    blocked_keys =
      Enum.map(reader_keys, fn _key ->
        assert_receive {:projection_reader_blocked, key, _reader}, 2_000
        key
      end)

    assert MapSet.new(blocked_keys) == MapSet.new(reader_keys)

    read = Task.async(fn -> CurrentRunSummary.snapshot(server: owner) end)
    visible = Task.await(read, 2_000)

    assert visible.generation == baseline.generation
    assert visible.freshness.status == :stale
    assert visible.freshness.refreshing?
    assert :source_refresh_in_progress in visible.health.reasons

    assert Task.await(refresh, 4_000) == :ok
    assert CurrentRunSummary.snapshot(server: owner).health.status == :unavailable
    assert Process.alive?(owner)
  end

  test "reader-boundary sanitization keeps raw issue and workspace facts out of owner state" do
    sentinel = "FORBIDDEN-RAW-WORKSPACE-#{System.unique_integer([:positive])}"
    test_pid = self()

    {source, owner, _pubsub} =
      start_owner(
        fn current ->
          current
          |> put_in([:run, :workspace_path], sentinel)
          |> put_in([:membership, :members, Access.at(0), :raw_issue], %{body: sentinel})
          |> put_in([:membership, :members, Access.at(0), :workspace_path], sentinel)
          |> put_in([:status, :running, Access.at(0), :title], sentinel)
          |> put_in([:status_facts, Access.at(0), :body], sentinel)
          |> put_in([:status_facts, Access.at(0), :workspace_path], sentinel)
          |> put_in([:activity, :entries, Access.at(0), :raw_issue], sentinel)
          |> update_in([:merges, :merges, Access.at(0)], &%{&1 | content_hash: sentinel})
        end,
        checkpoint_writer: fn _run_id, checkpoint ->
          send(test_pid, {:sanitized_projection_checkpoint, checkpoint})
          :ok
        end
      )

    assert :ok = CurrentRunProjections.refresh(owner)
    assert_receive {:sanitized_projection_checkpoint, checkpoint}, 2_000
    state_text = inspect(:sys.get_state(owner), limit: :infinity, printable_limit: :infinity)
    checkpoint_text = inspect(checkpoint, limit: :infinity, printable_limit: :infinity)

    refute state_text =~ sentinel
    refute checkpoint_text =~ sentinel
    refute inspect(CurrentRunSummary.snapshot(server: owner), limit: :infinity) =~ sentinel
    refute inspect(CurrentRunOutcomeSnapshot.snapshot(server: owner), limit: :infinity) =~ sentinel
    assert Process.alive?(source)
  end

  test "checkpoint fallback collections remain bounded" do
    oversized = Enum.map(1..1_001, &%{identity: identity(&1)})

    checkpoint =
      Checkpoint.dump(%{
        sources: %{
          membership: %{members: oversized, truncated?: false},
          status: %{running: oversized, retrying: oversized, idle: oversized},
          status_facts: oversized,
          activity: %{entries: oversized},
          merges: %{merges: oversized}
        },
        units: %{rows: oversized},
        weight_facts: Map.new(1..1_001, &{&1, %{complexity: 1}})
      })

    assert length(checkpoint.sources.membership.members) == 1_000
    assert checkpoint.sources.membership.truncated?
    assert length(checkpoint.sources.status.running) == 1_000
    assert length(checkpoint.sources.status_facts) == 1_000
    assert length(checkpoint.sources.activity.entries) == 1_000
    assert length(checkpoint.sources.merges.merges) == 1_000
    assert length(checkpoint.units.rows) == 1_000
    assert map_size(checkpoint.weight_facts) == 1_000
  end

  test "membership generation fences outcome last-known-good snapshots" do
    {source, owner, _pubsub} = start_owner()
    assert :ok = CurrentRunProjections.refresh(owner)
    good = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert good.state == :healthy

    Agent.update(source, fn current ->
      current
      |> put_in([:membership, :generation], current.membership.generation + 1)
      |> Map.put(:merges, :timeout)
    end)

    assert :ok = CurrentRunProjections.refresh(owner)
    degraded = CurrentRunOutcomeSnapshot.snapshot(server: owner)

    assert degraded.membership.signature == good.membership.signature
    assert degraded.membership.generation == good.membership.generation + 1
    assert degraded.state == :unavailable
    assert degraded.last_known_good == nil
  end
end
