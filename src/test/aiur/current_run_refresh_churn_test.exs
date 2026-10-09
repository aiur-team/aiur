defmodule Aiur.CurrentRunRefreshChurnTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]

  alias Aiur.{CurrentRunProjections, CurrentRunSummary}
  alias Aiur.CurrentRunProjections.State
  alias AiurWeb.OperatorControlCenter.UnitsRow

  test "unchanged full inputs project once, including when only the clock advances" do
    {source, owner, builds, _reads} = start_owner()
    for _ <- 1..20, do: assert(:ok = CurrentRunProjections.refresh(owner))
    assert Agent.get(builds, & &1) == 1
    initial = CurrentRunSummary.snapshot(server: owner)
    Agent.update(source, &put_in(&1, [:run, :elapsed_ms], 2_000))
    assert :ok = CurrentRunProjections.refresh(owner)
    assert Agent.get(builds, & &1) == 1
    assert CurrentRunSummary.snapshot(server: owner).run.elapsed_wall_ms == 2_000
    assert CurrentRunSummary.snapshot(server: owner).generation > initial.generation
    refute CurrentRunSummary.snapshot(server: owner).sources[:refreshing?]
    Agent.update(source, &put_in(&1, [:membership, :health], {:unavailable, :outage}))
    assert :ok = CurrentRunProjections.refresh(owner)
    assert Agent.get(builds, & &1) == 2
    assert CurrentRunSummary.health(server: owner).status != :healthy
    Agent.update(source, &put_in(&1, [:membership, :health], :healthy))
    assert :ok = CurrentRunProjections.refresh(owner)
    assert Agent.get(builds, & &1) == 3
    assert CurrentRunSummary.health(server: owner).status == :healthy
  end

  test "notification burst collects sources once" do
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, CurrentRunSummary.topic())
    {_source, owner, builds, reads} = start_owner(pubsub: pubsub)
    :sys.suspend(owner)
    for _ <- 1..100, do: send(owner, {:status_changed, %{}})
    :sys.resume(owner)
    _ = CurrentRunSummary.snapshot(server: owner)
    {:current_run_summary_changed, snapshot} = receive_barrier({:current_run_summary_changed, _})
    assert snapshot.health.status == :healthy
    state = :sys.get_state(owner)
    refute state.refresh_pending?
    refute state.refresh_again?
    assert Agent.get(reads, & &1) == 1
    assert Agent.get(builds, & &1) == 1
  end

  defp start_owner(extra_opts \\ []) do
    sources = %{
      State.empty_sources()
      | run: %{id: "refresh-run", started_at: ~U[2026-10-08 00:00:00Z], observed_at: ~U[2026-10-08 00:00:01Z], elapsed_ms: 1_000},
        membership: %{run_id: "refresh-run", generation: 0, health: :healthy, freshness: %{status: :fresh}, members: [], truncated?: false},
        status: %{running: [], retrying: [], idle: []},
        activity: %{generation: 0, entries: []},
        merges: %{generation: 0, merges: [], health: :writable, reconciliation: %{status: :complete, partial?: false, pages_fetched: 1}},
        configured_repository: {:ok, {"aiur-team", "aiur"}}
    }

    source = start_supervised!({Agent, fn -> sources end})
    builds = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :builds))
    reads = start_supervised!(Supervisor.child_spec({Agent, fn -> 0 end}, id: :reads))

    options = [
      name: nil,
      pubsub: nil,
      subscribe_funs: [],
      task_supervisor: nil,
      refresh_on_init?: false,
      clock_interval_ms: :infinity,
      reconcile_interval_ms: :infinity,
      checkpoint_interval_ms: 1,
      units_snapshot_fun: fn inputs ->
        Agent.update(builds, &(&1 + 1))
        UnitsRow.snapshot(inputs)
      end
    ]

    options =
      Enum.reduce(
        [
          run: :run_snapshot_fun,
          membership: :membership_snapshot_fun,
          status: :status_snapshot_fun,
          status_facts: :status_facts_fun,
          activity: :activity_snapshot_fun,
          merges: :recent_merges_snapshot_fun,
          configured_repository: :configured_repository_fun
        ],
        options,
        fn {key, option}, acc ->
          Keyword.put(acc, option, fn -> read_source(source, reads, key) end)
        end
      )

    owner = start_supervised!({CurrentRunProjections, Keyword.merge(options, extra_opts)})
    {source, owner, builds, reads}
  end

  defp read_source(source, reads, key) do
    if key == :membership, do: Agent.update(reads, &(&1 + 1))
    Agent.get(source, &Map.fetch!(&1, key))
  end
end
