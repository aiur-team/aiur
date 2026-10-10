defmodule AiurWeb.OperatorControlCenter.UnitsRetainedPayloadTest do
  # #3937: a failed dashboard load re-serves the previous payload. The Units page
  # must name that as stale, and must keep re-reading without waiting for an event.
  use Aiur.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Aiur.TrackerIdentity
  alias AiurWeb.{ControlCenterCache, Endpoint}
  alias AiurWeb.OperatorControlCenter.{PayloadLoader, UnitsPresenter, UnitsTable}

  @endpoint Endpoint

  defp start_endpoint(overrides) do
    previous = Application.fetch_env(:aiur, Endpoint)
    cache = start_supervised!({ControlCenterCache, name: nil})

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
  end

  test "a failed load demotes the retained Units catalog to stale with its age" do
    {:ok, fail?} = Agent.start_link(fn -> false end)

    # A kill is the one failure the provider guards cannot turn into a
    # successful degraded load, so it reaches the cache's retained path.
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
    Process.sleep(1_100)
    retained = PayloadLoader.load(:fresh)

    assert retained.stale == true
    assert retained.units.status == :stale
    assert retained.units.retained_age_seconds in 1..3
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

  test "the Units page re-reads its payload on the periodic tick, not only on events" do
    test_pid = self()

    start_endpoint(
      control_center_reload_timer: fn pid, message, _delay_ms ->
        send(test_pid, :reload_scheduled)
        send(pid, message)
        make_ref()
      end
    )

    conn = Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))
    {:ok, view, _html} = live(conn, "/")
    _settled = render(view)
    flush(:reload_scheduled)

    send(view.pid, :github_quota_tick)
    _rendered = render(view)
    assert_receive :reload_scheduled, 1_000
  end

  defp flush(message) do
    receive do
      ^message -> flush(message)
    after
      0 -> :ok
    end
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
