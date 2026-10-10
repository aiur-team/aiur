defmodule AiurWeb.OperatorControlCenter.UnitsRetainedPayloadTest do
  # #3937: one slow provider must not fail the whole dashboard load, and when a
  # load does fail the Units page must name the re-served list as stale and keep
  # re-reading without waiting for an event.
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.Orchestrator.SnapshotStore
  alias Aiur.TrackerIdentity
  alias AiurWeb.{ControlCenterCache, Endpoint}
  alias AiurWeb.OperatorControlCenter.{PayloadLoader, UnitsPresenter, UnitsTable}

  @endpoint Endpoint
  @orchestrator __MODULE__.Orchestrator

  # The cache reads this clock, so a retained payload's age is set, not slept for.
  defp start_endpoint(overrides, cache_opts \\ []) do
    previous = Application.fetch_env(:aiur, Endpoint)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    cache = start_supervised!({ControlCenterCache, [name: nil, clock: fn -> Agent.get(clock, & &1) end] ++ cache_opts})

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

    Application.put_env(:aiur, Endpoint, config)
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

  test "a retained catalog renders its age and no old runtimes" do
    catalog = %{status: :ready, message: nil, truncated?: false, snapshot: %{rows: [row()], truncated?: false}}
    render = fn catalog -> render_component(&UnitsTable.units_table/1, %{view: UnitsPresenter.project(catalog, nil), now: ~U[2026-07-17 12:00:00Z]}) end

    current = render.(catalog)
    assert current =~ "1h 5m"
    refute current =~ "Stale list."

    retained = render.(Map.merge(catalog, %{status: :stale, retained_age_seconds: 192}))
    assert retained =~ "<b>Stale list.</b> The last refresh failed. These units were last read 3m 12s ago."
    assert retained =~ ~s(<span class="sr-only">Runtime </span>Stale)
    refute retained =~ "1h 5m"
  end

  test "the page shows a stale list with its age, then one tick brings in a newly running agent" do
    first = identity(1110)
    second = identity(1111)
    {:ok, running} = Agent.start_link(fn -> [first] end)
    {:ok, blocked?} = Agent.start_link(fn -> false end)
    publish_running([first])

    # The provider deadline is deliberately longer than this cache's load
    # timeout: that is the overrun the page has to survive, whatever causes it.
    clock =
      start_endpoint(
        [
          orchestrator: @orchestrator,
          control_center_provider_budget_ms: 60_000,
          units_membership_fun: fn -> membership(Agent.get(running, & &1)) end,
          units_activity_fun: fn ->
            if Agent.get(blocked?, & &1), do: Process.sleep(:infinity)
            %{generation: 1, health: :healthy, freshness: %{status: :fresh}, entries: []}
          end,
          control_center_reload_timer: fn pid, message, _delay_ms ->
            send(pid, message)
            make_ref()
          end
        ],
        load_timeout_ms: 100
      )

    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
    {:ok, view, _html} = live(conn, "/")
    current = render(view)
    assert length(unit_rows(current)) == 1
    refute current =~ "Stale list."

    Agent.update(blocked?, fn _ -> true end)
    advance(clock, 192_000)
    tick(view)
    stale = render(view)

    assert stale =~ "<b>Stale list.</b> The last refresh failed. These units were last read 3m 12s ago."
    assert stale =~ ~s(<span class="sr-only">Runtime </span>Stale)
    assert length(unit_rows(stale)) == 1

    Agent.update(blocked?, fn _ -> false end)
    Agent.update(running, fn _ -> [first, second] end)
    publish_running([first, second])
    advance(clock, 15_000)
    tick(view)
    recovered = render(view)

    refute recovered =~ "Stale list."
    refute recovered =~ ~s(<span class="sr-only">Runtime </span>Stale)
    assert length(unit_rows(recovered)) == 2
    assert recovered =~ "Unit 1111"
  end

  # The tick queues the reload behind itself; wait for the tick before rendering.
  defp tick(view) do
    send(view.pid, :github_quota_tick)
    _state = :sys.get_state(view.pid)
  end

  defp unit_rows(html), do: html |> Floki.parse_document!() |> Floki.find("#units-rows .units-row")

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

  defp row do
    %{
      identity: %TrackerIdentity{
        status: :joinable,
        kind: :github,
        owner: "acme",
        repository: "aiur",
        provider_id: "NODE-1110",
        database_id: 1110,
        identifier: "1110",
        reason: nil
      },
      title: "Responsive Units interface",
      url: "https://github.com/acme/aiur/issues/1110",
      lifecycle: :active,
      terminal?: false,
      replacement_boundary?: false,
      tracker_state: "in-progress",
      backend: :codex,
      agent_family: :codex,
      requested_model: "gpt-5.6-terra",
      resolved_model: "gpt-5.6",
      effort: :high,
      account: nil,
      complexity: 3,
      build_lane: "L2",
      reasons: %{waiting: :active, blocking: nil, alert: nil, pause: nil, stuck: nil},
      runtime: %{
        bucket: :running,
        work_state: :working,
        waiting_reason: :active,
        runtime_seconds: 3_900,
        stale_for_seconds: 15,
        tracker_paused?: false,
        membership_lifecycle: :active
      },
      timestamps: %{
        first_observed_at: ~U[2026-07-17 10:00:00Z],
        last_observed_at: ~U[2026-07-17 11:59:00Z],
        started_at: "2026-07-17T10:55:00Z",
        last_activity_at: "2026-07-17T11:59:00Z"
      },
      open_command_count: 0,
      turn_count: 3,
      context_usage: %{used_tokens: 50_000, window_tokens: 100_000},
      progress: %{status: :known, percent: 40, source: :checkin, freshness: :stale},
      latest_evidence: %{status: :known, source: %{kind: :branch, name: "feature pushed"}},
      provider_health: %{membership: :available, status: :available, activity: :available, decisions: :available, issue: :available},
      field_sources: %{},
      sources: %{}
    }
  end
end
