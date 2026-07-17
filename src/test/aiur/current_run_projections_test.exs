defmodule Aiur.CurrentRunProjectionsTest do
  use ExUnit.Case, async: true

  alias Aiur.{
    CurrentRunOutcomeSnapshot,
    CurrentRunProjections,
    CurrentRunSummary,
    RecentMerge,
    TrackerIdentity
  }

  alias Aiur.CurrentRunOutcomeSnapshot.MembershipIndex

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

  test "status reader failures mark retained status and issue facts stale" do
    {source, owner, _pubsub} = start_owner()
    :ok = CurrentRunProjections.refresh(owner)
    good = CurrentRunSummary.snapshot(server: owner)

    Agent.update(source, &Map.put(&1, :status, :timeout))
    assert :ok = CurrentRunProjections.refresh(owner)

    status_stale = CurrentRunSummary.snapshot(server: owner)
    assert status_stale.health.status == :partial
    assert status_stale.sources.status_health == :unavailable
    assert status_stale.freshness.status == :stale
    assert status_stale.last_known_good.generation == good.generation

    Agent.update(source, fn current ->
      current
      |> Map.put(:status, sources().status)
      |> Map.put(:status_facts, :timeout)
    end)

    assert :ok = CurrentRunProjections.refresh(owner)

    issue_stale = CurrentRunSummary.snapshot(server: owner)
    assert issue_stale.health.status == :partial
    assert issue_stale.sources.issue_health == :degraded
    assert issue_stale.sources.weight_health == :unavailable
    assert issue_stale.freshness.status == :stale
    assert issue_stale.last_known_good.generation == good.generation
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

    {source, owner, _pubsub} =
      start_owner(fn current ->
        current
        |> put_in([:run, :workspace_path], sentinel)
        |> put_in([:membership, :members, Access.at(0), :raw_issue], %{body: sentinel})
        |> put_in([:membership, :members, Access.at(0), :workspace_path], sentinel)
        |> put_in([:status, :running, Access.at(0), :title], sentinel)
        |> put_in([:status_facts, Access.at(0), :body], sentinel)
        |> put_in([:status_facts, Access.at(0), :workspace_path], sentinel)
        |> put_in([:activity, :entries, Access.at(0), :raw_issue], sentinel)
        |> update_in([:merges, :merges, Access.at(0)], &%{&1 | content_hash: sentinel})
      end)

    assert :ok = CurrentRunProjections.refresh(owner)
    state_text = inspect(:sys.get_state(owner), limit: :infinity, printable_limit: :infinity)

    refute state_text =~ sentinel
    refute inspect(CurrentRunSummary.snapshot(server: owner), limit: :infinity) =~ sentinel
    refute inspect(CurrentRunOutcomeSnapshot.snapshot(server: owner), limit: :infinity) =~ sentinel
    assert Process.alive?(source)
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

  test "merge and configured-repository outages cannot report fresh outcomes" do
    {source, owner, _pubsub} = start_owner()
    baseline = sources()
    assert :ok = CurrentRunProjections.refresh(owner)

    for {key, reason} <- [merges: :merge_source_unavailable, configured_repository: :configured_repository_unavailable] do
      Agent.update(source, &Map.put(&1, key, :timeout))
      assert :ok = CurrentRunProjections.refresh(owner)
      snapshot = CurrentRunOutcomeSnapshot.snapshot(server: owner)

      assert snapshot.state == :unavailable
      assert snapshot.freshness.status == :unavailable
      assert reason in snapshot.health.reasons

      Agent.update(source, &Map.put(&1, key, Map.fetch!(baseline, key)))
      assert :ok = CurrentRunProjections.refresh(owner)
      assert CurrentRunOutcomeSnapshot.snapshot(server: owner).freshness.status == :fresh
    end
  end

  test "membership indexes rebuild only when the authoritative generation changes" do
    counter = :counters.new(1, [:atomics])

    membership_index_fun = fn members ->
      :counters.add(counter, 1, 1)
      MembershipIndex.build(members)
    end

    {source, owner, _pubsub} = start_owner(fn value -> value end, membership_index_fun: membership_index_fun)
    assert :ok = CurrentRunProjections.refresh(owner)
    outcomes = CurrentRunOutcomeSnapshot.snapshot(server: owner)
    assert :counters.get(counter, 1) == 1
    assert Agent.get(source, &Map.get(&1, :membership_reads, 0)) == 1
    assert Agent.get(source, &Map.get(&1, :merges_reads, 0)) == 1

    send(owner, :clock_tick)

    assert eventually(fn ->
             state = :sys.get_state(owner)
             Agent.get(source, & &1.run_reads) == 2 and is_nil(state.refresh)
           end)

    assert Agent.get(source, &Map.get(&1, :membership_reads, 0)) == 1
    assert Agent.get(source, &Map.get(&1, :merges_reads, 0)) == 1
    assert :counters.get(counter, 1) == 1
    assert CurrentRunOutcomeSnapshot.snapshot(server: owner) == outcomes

    assert :ok = CurrentRunProjections.refresh(owner)
    assert :counters.get(counter, 1) == 1

    Agent.update(source, &update_in(&1, [:membership, :generation], fn generation -> generation + 1 end))

    assert :ok = CurrentRunProjections.refresh(owner)
    assert :counters.get(counter, 1) == 2
  end

  test "same-run supervised restart preserves terminal weights and public generations" do
    source = start_supervised!({Agent, fn -> weighted_sources() end})

    checkpoint =
      start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: unique_name(:checkpoint)))

    pubsub = unique_name(:restart_pubsub)
    name = unique_name(:restart_owner)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    checkpoint_reader = fn ->
      %{run_id: "run-1", checkpoint: Agent.get(checkpoint, &Map.get(&1, "run-1"))}
    end

    checkpoint_writer = fn run_id, value -> Agent.update(checkpoint, &Map.put(&1, run_id, value)) end

    opts =
      owner_options(source, pubsub,
        name: name,
        checkpoint_reader: checkpoint_reader,
        checkpoint_writer: checkpoint_writer
      )

    {:ok, supervisor} = Supervisor.start_link([{CurrentRunProjections, opts}], strategy: :one_for_one)
    on_exit(fn -> if Process.alive?(supervisor), do: Supervisor.stop(supervisor) end)

    assert :ok = CurrentRunProjections.refresh(name)

    Agent.update(source, fn current ->
      Map.put(current, :status_facts, [List.last(current.status_facts)])
    end)

    assert :ok = CurrentRunProjections.refresh(name)
    before_restart = CurrentRunSummary.snapshot(server: name)

    assert before_restart.weights.eligible == 10
    assert before_restart.weights.successful_terminal == 5
    assert before_restart.weights.remaining == 5
    assert before_restart.progress.exact == %{numerator: 3, denominator: 5}
    assert before_restart.eta.status == :available
    assert before_restart.eta.completed_weight == 5
    assert before_restart.eta.throughput_weight_per_second == %{numerator: 1, denominator: 1_440}

    first_owner = Process.whereis(name)
    Process.exit(first_owner, :kill)

    assert eventually(fn ->
             restarted = Process.whereis(name)
             is_pid(restarted) and restarted != first_owner
           end)

    restored = CurrentRunSummary.snapshot(server: name)
    assert restored.generation == before_restart.generation
    assert restored.denominator.generation == before_restart.denominator.generation

    assert :ok = CurrentRunProjections.refresh(name)
    after_restart = CurrentRunSummary.snapshot(server: name)

    assert after_restart.generation == before_restart.generation
    assert after_restart.denominator == before_restart.denominator
    assert after_restart.weights == before_restart.weights
    assert after_restart.progress == before_restart.progress
    assert after_restart.eta == before_restart.eta
  end

  defp start_owner(transform \\ fn value -> value end, extra_opts \\ []) do
    source = start_supervised!({Agent, fn -> transform.(sources()) end})
    pubsub = unique_name(:pubsub)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    owner = start_supervised!({CurrentRunProjections, owner_options(source, pubsub, extra_opts)})

    {source, owner, pubsub}
  end

  defp owner_options(source, pubsub, extra_opts) do
    Keyword.merge(
      [
        name: nil,
        pubsub: pubsub,
        subscribe_funs: [],
        refresh_on_init?: false,
        clock_interval_ms: :infinity,
        reconcile_interval_ms: :infinity,
        run_snapshot_fun: source_reader(source, :run),
        membership_snapshot_fun: source_reader(source, :membership),
        status_snapshot_fun: source_reader(source, :status),
        status_facts_fun: source_reader(source, :status_facts),
        activity_snapshot_fun: source_reader(source, :activity),
        recent_merges_snapshot_fun: source_reader(source, :merges),
        configured_repository_fun: source_reader(source, :configured_repository)
      ],
      extra_opts
    )
  end

  defp source_reader(source, key) do
    fn ->
      value = Agent.get_and_update(source, &read_source(&1, key))
      read_value(value, key)
    end
  end

  defp read_source(sources, key) do
    counter = String.to_atom("#{key}_reads")
    {Map.fetch!(sources, key), Map.update(sources, counter, 1, &(&1 + 1))}
  end

  defp read_value({:block, notify}, key) when is_pid(notify) do
    send(notify, {:projection_reader_blocked, key, self()})

    receive do
      {:release_projection_reader, ^key, value} -> value
    end
  end

  defp read_value(value, _key), do: value

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

  defp weighted_sources do
    first = identity(32)
    second = identity(33)
    active = identity(34)

    sources()
    |> put_in([:membership, :members], [
      member(first, :completed, true),
      member(second, :completed, true),
      member(active, :running, false)
    ])
    |> put_in([:status, :running], [status_row(active)])
    |> put_in([:status_facts], [
      status_fact(first, "done", 2),
      status_fact(second, "done", 3),
      status_fact(active, "in-progress", 5)
    ])
    |> put_in([:activity, :entries], [
      activity_entry(first, 100),
      activity_entry(second, 100),
      activity_entry(active, 20)
    ])
  end

  defp member(ticket, lifecycle, terminal?) do
    %{
      identity: ticket,
      lifecycle: lifecycle,
      terminal?: terminal?,
      first_observed_at: ~U[2026-07-17 10:00:00Z],
      last_observed_at: ~U[2026-07-17 11:59:00Z]
    }
  end

  defp status_row(ticket) do
    %{
      tracker_identity: ticket,
      state: "in-progress",
      work_state: :working,
      waiting_reason: :active,
      runtime_seconds: 600,
      open_decision_count: 0
    }
  end

  defp status_fact(ticket, state, complexity) do
    %{tracker_identity: ticket, state: state, complexity: complexity}
  end

  defp identity(number \\ 32) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "NODE-#{number}",
      identifier: Integer.to_string(number),
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
