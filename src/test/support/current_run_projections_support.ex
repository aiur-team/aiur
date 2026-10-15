defmodule Aiur.CurrentRunProjectionsSupport do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Aiur.CurrentRunProjections
  alias Aiur.RecentMerge
  alias Aiur.TrackerIdentity
  alias AiurWeb.ObservabilityPubSub

  def start_owner(transform \\ fn value -> value end, extra_opts \\ []) do
    source = start_supervised!({Agent, fn -> transform.(sources()) end})
    pubsub = unique_name(:pubsub)
    start_supervised!({Phoenix.PubSub, name: pubsub})

    extra_opts =
      if Keyword.get(extra_opts, :observability_subscription?, false) do
        Keyword.put(extra_opts, :subscribe_funs, [fn -> ObservabilityPubSub.subscribe(pubsub) end])
      else
        extra_opts
      end

    owner = start_supervised!({CurrentRunProjections, owner_options(source, pubsub, extra_opts)})

    {source, owner, pubsub}
  end

  def await_projection_idle(owner, attempts \\ 1_000)

  def await_projection_idle(_owner, 0), do: flunk("projection owner did not become idle")

  def await_projection_idle(owner, attempts) do
    state = :sys.get_state(owner)

    if is_nil(state.refresh) and is_nil(state.checkpoint_write) and not state.refresh_pending? do
      :ok
    else
      Process.sleep(5)
      await_projection_idle(owner, attempts - 1)
    end
  end

  def owner_options(source, pubsub, extra_opts) do
    subscribe_funs = Keyword.get(extra_opts, :subscribe_funs, [])

    Keyword.merge(
      [
        name: nil,
        pubsub: pubsub,
        subscribe_funs: subscribe_funs,
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

  def source_reader(source, key) do
    fn ->
      value = Agent.get_and_update(source, &read_source(&1, key))
      read_value(value, key)
    end
  end

  def read_source(sources, key) do
    counter = String.to_atom("#{key}_reads")
    {Map.fetch!(sources, key), Map.update(sources, counter, 1, &(&1 + 1))}
  end

  def read_value({:block, notify}, key) when is_pid(notify) do
    send(notify, {:projection_reader_blocked, key, self()})

    receive do
      {:release_projection_reader, ^key, value} -> value
    end
  end

  def read_value(value, _key), do: value

  def wait_for_refresh_waiters(owner, expected, attempts \\ 1_000)

  def wait_for_refresh_waiters(_owner, _expected, 0), do: false

  def wait_for_refresh_waiters(owner, expected, attempts) do
    state = :sys.get_state(owner)
    active = state.refresh |> Map.get(:waiters, []) |> length()
    queued = length(state.queued_waiters)

    if active + queued == expected do
      true
    else
      Process.sleep(1)
      wait_for_refresh_waiters(owner, expected, attempts - 1)
    end
  end

  def sources do
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

  def activity_entry(ticket, percent) do
    %{
      identity: ticket,
      progress: %{status: :known, percent: percent, source: :checkin, freshness: :fresh}
    }
  end

  def weighted_sources do
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

  def member(ticket, lifecycle, terminal?) do
    %{
      identity: ticket,
      lifecycle: lifecycle,
      terminal?: terminal?,
      first_observed_at: ~U[2026-07-17 10:00:00Z],
      last_observed_at: ~U[2026-07-17 11:59:00Z]
    }
  end

  def status_row(ticket) do
    %{
      tracker_identity: ticket,
      state: "in-progress",
      work_state: :working,
      waiting_reason: :active,
      runtime_seconds: 600,
      open_decision_count: 0
    }
  end

  def status_fact(ticket, state, complexity) do
    %{tracker_identity: ticket, state: state, complexity: complexity}
  end

  def identity(number \\ 32) do
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

  def merge do
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

  def unique_name(suffix) do
    String.to_atom("current_run_projections_#{suffix}_#{System.unique_integer([:positive])}")
  end

  def report_messages(test_pid) do
    receive do
      message ->
        send(test_pid, {:orchestrator_message, message})
        report_messages(test_pid)
    end
  end
end
