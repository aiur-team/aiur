defmodule AiurWeb.OperatorControlCenter.UnitsRetainedPayloadTest do
  # #3937: one slow provider must not fail a load; retained catalog snapshots
  # must name stale data and preserve its measured age.
  use Aiur.TestSupport

  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity
  alias AiurWeb.{ControlCenterCache, Endpoint}
  alias AiurWeb.OperatorControlCenter.{PayloadLoader, UnitsPresenter}

  @orchestrator __MODULE__.Orchestrator

  # The cache reads this clock, so a retained payload's age is set, not slept for.
  defp start_endpoint(overrides, cache_opts \\ []) do
    previous = Application.fetch_env(:aiur, Endpoint)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    cache_opts = Keyword.merge([name: nil, clock: fn -> Agent.get(clock, & &1) end], cache_opts)
    cache = start_supervised!({ControlCenterCache, cache_opts})

    config =
      Application.get_env(:aiur, Endpoint, [])
      |> Keyword.merge(
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: false,
        dashboard_writable: false,
        control_center_cache: cache,
        orchestrator: __MODULE__.MissingOrchestrator
      )
      |> Keyword.merge(overrides)

    Application.put_env(:aiur, Endpoint, EndpointStubs.scope(config))
    on_exit(fn -> Aiur.TestSupport.restore_app_env([{Endpoint, previous}]) end)
    Aiur.TestSupport.start_owned_endpoint!()
    clock
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp publish_running(identities) do
    on_exit(fn -> SnapshotStore.forget(@orchestrator) end)

    :ok =
      SnapshotStore.publish(@orchestrator, %{
        running: Enum.map(identities, &running/1),
        retrying: [],
        idle: [],
        agent_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        rate_limits: nil
      })
  end

  test "a provider that never answers degrades its own surface, not the Units catalog" do
    identity = identity(1110)
    publish_running([identity])
    silent_store = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(silent_store, :kill) end)

    start_endpoint(
      orchestrator: @orchestrator,
      control_center_provider_budget_ms: 400,
      recent_merge_store: silent_store,
      units_membership_fun: fn -> membership([identity]) end,
      units_activity_fun: fn -> Process.sleep(:infinity) end
    )

    started = System.monotonic_time(:millisecond)
    payload = PayloadLoader.load(:fresh)

    # Inside the budget, far inside the cache's 4 s kill.
    assert System.monotonic_time(:millisecond) - started < 2_000
    refute Map.has_key?(payload, :stale)
    assert payload.provider_health.fleet == :ok
    assert payload.provider_health.recent_outcomes == :unavailable
    assert [%{identity: ^identity, runtime: %{bucket: :running, work_state: :working}}] = payload.units.snapshot.rows
    refute Map.has_key?(payload.units, :retained_age_seconds)
  end

  test "an unpublished snapshot marks the loaded Units catalog as starting" do
    :ok = SnapshotStore.forget(@orchestrator)
    {:ok, orchestrator} = Agent.start_link(fn -> :starting end, name: @orchestrator)

    on_exit(fn ->
      if Process.alive?(orchestrator), do: Agent.stop(orchestrator)
      SnapshotStore.forget(@orchestrator)
    end)

    start_endpoint([orchestrator: @orchestrator], boot_elapsed_ms: fn -> 0 end)
    payload = PayloadLoader.load(:fresh)

    assert payload.units.status == :loading
    assert UnitsPresenter.project(payload.units, nil).count_status == :loading
  end

  test "the cache keeps an unobserved stale fleet loading only until the boot deadline" do
    boot = :atomics.new(1, [])
    cache_clock = :atomics.new(1, [])
    :atomics.put(boot, 1, 0)
    :atomics.put(cache_clock, 1, 0)

    start_endpoint(
      [units_fleet_fun: fn -> %{error: %{code: "snapshot_timeout", message: "Fleet snapshot timed out."}} end],
      clock: fn -> :atomics.get(cache_clock, 1) end,
      boot_elapsed_ms: fn -> :atomics.get(boot, 1) end,
      startup_observation_timeout_ms: 100
    )

    pending = PayloadLoader.load(:fresh)
    assert pending.units.status == :loading
    assert pending.units.message == "The daemon is starting."
    assert UnitsPresenter.project(pending.units, nil).count_status == :loading

    :atomics.put(cache_clock, 1, 100_000)
    assert PayloadLoader.load(:fresh).units.status == :loading

    :atomics.put(boot, 1, 100)
    unavailable = PayloadLoader.load(:fresh)

    assert unavailable.units.status == :unavailable
    assert unavailable.units.message == "No live units. Fleet data is unavailable."
    assert UnitsPresenter.project(unavailable.units, nil).count_status == :unavailable
  end

  test "a timed out cold cache load keeps startup markers through payload conversion" do
    boot = :atomics.new(1, [])
    cache_clock = :atomics.new(1, [])
    :atomics.put(boot, 1, 0)
    :atomics.put(cache_clock, 1, 0)

    start_endpoint(
      [control_center_provider_budget_ms: 60_000, units_fleet_fun: fn -> Process.sleep(:infinity) end],
      clock: fn -> :atomics.get(cache_clock, 1) end,
      boot_elapsed_ms: fn -> :atomics.get(boot, 1) end,
      startup_observation_timeout_ms: 100,
      load_timeout_ms: 100
    )

    pending = PayloadLoader.load(:fresh)
    assert pending.units.status == :loading

    :atomics.put(cache_clock, 1, 100_000)
    assert PayloadLoader.load(:fresh).units.status == :loading

    :atomics.put(boot, 1, 100)
    unavailable = PayloadLoader.load(:fresh)
    assert unavailable.units.status == :unavailable
    assert unavailable.units.message == "Fleet data is unavailable."
  end

  test "a failed load demotes the retained Units catalog to stale with its age" do
    {:ok, fail?} = Agent.start_link(fn -> false end)

    # A kill is the one failure the provider guards cannot turn into a
    # successful degraded load, so it reaches the cache's retained path.
    clock =
      start_endpoint(
        units_fleet_fun: fn ->
          if Agent.get(fail?, & &1), do: Process.exit(self(), :kill)
          %{}
        end
      )

    loaded = PayloadLoader.load(:fresh)
    refute Map.has_key?(loaded, :stale)
    refute Map.has_key?(loaded.units, :retained_age_seconds)

    Agent.update(fail?, fn _ -> true end)
    advance(clock, 192_400)
    retained = PayloadLoader.load(:fresh)

    assert retained.stale == true
    assert retained.units.status == :stale
    assert retained.units.retained_age_seconds == 192
    assert retained.units.message == "Dashboard refresh failed; showing the last loaded units."
    assert retained.units.snapshot == loaded.units.snapshot

    Agent.update(fail?, fn _ -> false end)
    recovered = PayloadLoader.load(:fresh)
    assert recovered.units.status == loaded.units.status
    refute Map.has_key?(recovered.units, :retained_age_seconds)
  end

  defp identity(number) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "acme",
      repository: "aiur",
      provider_id: "NODE-#{number}",
      database_id: number,
      identifier: "#{number}",
      reason: nil
    }
  end

  defp membership(identities) do
    observed_at = DateTime.utc_now()

    %{
      run_id: "run-units",
      generation: length(identities),
      health: :healthy,
      health_message: nil,
      freshness: %{status: :fresh, observed_at: observed_at},
      members: Enum.map(identities, &%{identity: &1, lifecycle: :active, terminal?: false, first_observed_at: observed_at, last_observed_at: observed_at}),
      truncated?: false
    }
  end

  defp running(identity) do
    %{
      issue_id: "issue-#{identity.identifier}",
      identifier: identity.identifier,
      tracker_identity: identity,
      state: "in-progress",
      title: "Unit #{identity.identifier}",
      url: "https://github.com/acme/aiur/issues/#{identity.identifier}",
      labels: [],
      backend: :codex,
      agent_family: :codex,
      requested_model: "gpt-5.6-terra",
      resolved_model: nil,
      effort: :high,
      complexity: 3,
      build_lane: "L2",
      session_id: "session-#{identity.identifier}",
      started_at: DateTime.utc_now(),
      last_codex_timestamp: DateTime.utc_now(),
      last_codex_event: :progress,
      last_codex_message: "Working",
      runtime_seconds: 60,
      work_state: :working,
      tracker_paused: false,
      waiting_reason: :active,
      open_decision_count: 0,
      open_decision_count_health: :available,
      control: %{},
      ci_result: nil
    }
  end
end
