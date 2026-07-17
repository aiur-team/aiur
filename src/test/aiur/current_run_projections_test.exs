defmodule Aiur.CurrentRunProjectionsTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    CurrentRunOutcomeSnapshot,
    CurrentRunProjections,
    CurrentRunSummary,
    RecentMerge,
    TrackerIdentity
  }

  test "refreshes both projections, publishes changes, and serves read APIs" do
    {source, owner, pubsub} = start_owner()

    assert :ok = CurrentRunSummary.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunOutcomeSnapshot.subscribe(pubsub: pubsub)
    assert :ok = CurrentRunProjections.refresh(owner)

    assert_receive {:current_run_summary_changed, summary}
    assert_receive {:current_run_outcome_snapshot_changed, outcomes}

    assert summary.health.status == :healthy
    assert summary.freshness.status == :fresh
    assert summary.progress.exact == %{numerator: 2, denominator: 5}
    assert outcomes.state == :healthy
    assert outcomes.completeness == :complete
    assert length(outcomes.outcomes) == 1

    assert CurrentRunSummary.snapshot(server: owner) == summary
    assert CurrentRunSummary.health(server: owner) == summary.health
    assert CurrentRunSummary.freshness(server: owner) == summary.freshness
    assert CurrentRunSummary.generation(server: owner) == summary.generation

    assert CurrentRunOutcomeSnapshot.snapshot(server: owner) == outcomes
    assert CurrentRunOutcomeSnapshot.health(server: owner) == outcomes.health
    assert CurrentRunOutcomeSnapshot.generation(server: owner) == outcomes.generation
    assert Process.alive?(source)
  end

  test "a post-bootstrap run read failure exposes same-fence last-known-good snapshots" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)

    good_summary = CurrentRunSummary.snapshot(server: owner)
    good_outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert good_summary.health.status == :healthy
    assert good_outcomes.state == :healthy

    Agent.update(source, &Map.put(&1, :run, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)

    assert summary.health.status == :unavailable
    assert :invalid_run_window in summary.health.reasons
    assert summary.last_known_good.generation == good_summary.generation
    assert summary.last_known_good.snapshot.health.status == :healthy

    assert outcomes.state == :unavailable
    assert outcomes.last_known_good.generation == good_outcomes.generation
    assert outcomes.last_known_good.snapshot.state == :healthy
    assert Process.alive?(owner)
  end

  test "malformed activity degrades and a later timeout cannot crash the owner" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)

    valid_entry = activity_entry(identity(), 55)

    Agent.update(source, fn sources ->
      Map.put(sources, :activity, %{generation: 2, entries: [:malformed, valid_entry]})
    end)

    assert :ok = CurrentRunProjections.refresh(owner)
    summary = CurrentRunSummary.snapshot(server: owner)
    assert summary.health.status == :partial
    assert :unhealthy_activity in summary.health.reasons
    assert summary.sources.activity_health == :degraded
    assert Process.alive?(owner)

    Agent.update(source, &Map.put(&1, :activity, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    summary = CurrentRunSummary.snapshot(server: owner)
    assert summary.health.status == :partial
    assert summary.sources.activity_health == :unavailable
    assert summary.freshness.status == :stale
    assert Process.alive?(owner)
  end

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
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)
    assert Agent.get(source, & &1.run_reads) == 1

    :ok = :sys.suspend(owner)
    send(owner, {:ticket_activity_changed, %{}})
    send(owner, {:status_changed, %{}})
    send(owner, {:running_changed, %{}})
    :ok = :sys.resume(owner)

    assert eventually(fn -> Agent.get(source, & &1.run_reads) == 2 end)
    Process.sleep(20)
    assert Agent.get(source, & &1.run_reads) == 2
    assert CurrentRunSummary.health(server: owner).status == :healthy
    assert Process.alive?(owner)
  end

  defp start_owner(transform \\ fn value -> value end) do
    source = start_supervised!({Agent, fn -> transform.(sources()) end})
    pubsub = unique_name(:pubsub)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    read = fn key -> fn -> Agent.get(source, &Map.fetch!(&1, key)) end end

    read_run = fn ->
      Agent.get_and_update(source, fn sources ->
        {Map.fetch!(sources, :run), Map.update!(sources, :run_reads, &(&1 + 1))}
      end)
    end

    owner =
      start_supervised!(
        {CurrentRunProjections,
         name: nil,
         pubsub: pubsub,
         subscribe_funs: [],
         refresh_on_init?: false,
         clock_interval_ms: :infinity,
         reconcile_interval_ms: :infinity,
         run_snapshot_fun: read_run,
         membership_snapshot_fun: read.(:membership),
         status_snapshot_fun: read.(:status),
         status_facts_fun: read.(:status_facts),
         activity_snapshot_fun: read.(:activity),
         recent_merges_snapshot_fun: read.(:merges),
         configured_repository_fun: read.(:configured_repository)}
      )

    {source, owner, pubsub}
  end

  defp sources do
    ticket = identity()

    %{
      run_reads: 0,
      run: %{
        id: "run-1",
        started_at: ~U[2026-07-17 10:00:00Z],
        observed_at: ~U[2026-07-17 12:00:00Z],
        elapsed_ms: 7_200_000
      },
      membership: %{
        run_id: "run-1",
        generation: 3,
        health: :healthy,
        freshness: %{status: :fresh},
        truncated?: false,
        members: [
          %{
            identity: ticket,
            lifecycle: :running,
            terminal?: false,
            first_observed_at: ~U[2026-07-17 10:00:00Z],
            last_observed_at: ~U[2026-07-17 11:59:00Z]
          }
        ]
      },
      status: %{
        generation: 4,
        freshness: :fresh,
        running: [
          %{
            tracker_identity: ticket,
            state: "in-progress",
            work_state: :working,
            waiting_reason: :active,
            runtime_seconds: 600,
            open_decision_count: 0
          }
        ],
        retrying: [],
        idle: []
      },
      status_facts: [
        %{
          tracker_identity: ticket,
          title: "Current ticket",
          url: "https://github.com/owner/repo/issues/32",
          state: "in-progress",
          selected_backend: :codex,
          agent_family: :codex,
          requested_model: "gpt-5",
          effort: "high",
          complexity: 3,
          labels: ["complexity:3"]
        }
      ],
      activity: %{generation: 5, entries: [activity_entry(ticket, 40)]},
      merges: %{
        generation: 6,
        health: :writable,
        reconciliation: %{status: :complete, partial?: false, pages_fetched: 1},
        merges: [merge()]
      },
      configured_repository: {:ok, {"owner", "repo"}}
    }
  end

  defp activity_entry(ticket, percent) do
    %{
      identity: ticket,
      progress: %{status: :known, percent: percent, source: :checkin, freshness: :fresh}
    }
  end

  defp identity do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "NODE-32",
      identifier: "32",
      reason: nil
    }
  end

  defp merge do
    merged_at = ~U[2026-07-17 11:00:00Z]

    %RecentMerge{
      id: "owner/repo#32",
      repository: "owner/repo",
      number: 32,
      title: "Projection merge",
      summary: "Projection merge summary",
      url: "https://github.com/owner/repo/pull/32",
      head_ref: "aiur/32-projection",
      head_sha: "head-32",
      merge_commit_sha: "merge-32",
      merged_at: merged_at,
      observation_source: :github_events,
      backfilled?: true,
      live_observed?: false,
      observed_run_id: nil,
      first_observed_at: merged_at,
      last_observed_at: merged_at,
      content_hash: "hash-32"
    }
  end

  defp unique_name(suffix) do
    String.to_atom("current_run_projections_#{suffix}_#{System.unique_integer([:positive])}")
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
