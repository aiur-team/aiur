defmodule Aiur.Orchestrator.StatusReadModelTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.{AgentControlCLI, Boot, Issue}
  alias Aiur.Orchestrator.{Dispatcher, IssueSync, SnapshotStore, State, StatusObservation, StatusReport}
  alias AiurWeb.Presenter
  alias AiurWeb.OperatorControlCenter.{CapacityControl, CapacityPresenter, FleetTable, Overview}

  test "snapshot projection preserves all six renderer inputs and their behavior" do
    sample = %{load: 7.0, load_threshold: 8.0, target: 3, schedulers: 4}

    state = %State{
      orphaned_agent_reap_count: 17,
      startup_claim_reconciliation_complete?: true,
      dispatch_capacity_sample: sample,
      claimed: MapSet.new(["claimed"]),
      model_fallback_waiting: MapSet.new(["claimed"]),
      blocked_ticket_ids: MapSet.new(["blocked"])
    }

    input = StatusReport.snapshot_input(state)

    for key <- [:orphaned_agent_reap_count, :startup_claim_reconciliation_complete?, :dispatch_capacity_sample, :claimed, :model_fallback_waiting, :blocked_ticket_ids] do
      assert Map.fetch!(input, key) == Map.fetch!(state, key)
    end

    assert StatusReport.snapshot_payload(input).orphaned_agent_reap_count == 17
    assert StatusReport.snapshot_payload(input).capacity.load == 7.0
  end

  test "groups retain source timestamps and grow older at read time" do
    now = DateTime.utc_now()
    captured = DateTime.add(now, -10, :second)
    sample_time = DateTime.add(now, -60, :second)

    state = %State{
      last_dispatch_poll_at_ms: System.monotonic_time(:millisecond) - 30_000,
      dispatch_capacity_sample: %{observed_at: sample_time},
      tracker_observations: %{"44" => DateTime.add(now, -30, :second)}
    }

    input = StatusReport.snapshot_input(state) |> Map.put(:status_observed_at, captured)
    snapshot = StatusReport.snapshot_payload(input)
    assert snapshot.observations.fleet.observed_at == DateTime.to_iso8601(captured)
    assert snapshot.observations.fleet.age_ms >= 10_000
    assert snapshot.observations.per_ticket.age_ms >= 30_000
    assert snapshot.observations.dispatch.observed_at == DateTime.to_iso8601(sample_time)
    assert snapshot.observations.dispatch.age_ms >= 60_000
    assert snapshot.observations.capacity == Map.take(snapshot.capacity, [:observed_at, :age_ms])
    retained = StatusObservation.refresh(snapshot, DateTime.add(now, 120, :second))
    assert retained.observations.fleet.age_ms == 130_000
    assert retained.observations.dispatch.age_ms == 180_000
    assert retained.observations.retries.age_ms == 130_000
    assert retained.capacity.dispatch_observation == retained.observations.dispatch
  end

  test "successful tracker observations survive failed cycles and paused idle rows retain their age" do
    issue = %Issue{id: "idle", identifier: "idle", state: "todo", title: "Idle", paused: true, labels: ["agent:paused"]}
    synced = IssueSync.sync_polled_issue_state(%State{}, [issue], fn _ -> {:ok, []} end, fn _, _ -> :ok end, MapSet.new(["done"]), fn _ -> :ok end, fn _, _ -> :ok end)
    assert %DateTime{} = synced.tracker_observations[issue.id]
    observed = DateTime.add(synced.tracker_observations[issue.id], -60, :second)
    state = %{synced | tracker_observations: %{issue.id => observed}, last_dispatch_poll_at_ms: System.monotonic_time(:millisecond)}
    input = StatusReport.snapshot_input(state)
    snapshot = StatusReport.snapshot_payload(input)
    assert [idle] = snapshot.idle
    assert idle.work_state == :paused
    assert idle.observed_at == DateTime.to_iso8601(observed)
    assert idle.age_ms >= 60_000
    server = self()
    on_exit(fn -> SnapshotStore.forget(server) end)
    :ok = SnapshotStore.publish(server, snapshot, input)
    {:ok, cli, _} = StatusReport.fleet_view(server, 5_000, fleet_rows?: true)
    assert [row] = cli.statuses
    assert row.observed_at == idle.observed_at
    assert row.age_ms >= idle.age_ms
  end

  test "dispatch records the source time of a reused sample" do
    now_ms = System.monotonic_time(:millisecond)

    probes = %{
      memory_mb: 4_000,
      memory_threshold_mb: 2_048,
      fd_sample: :unavailable,
      runnable: :unavailable,
      run_queue_threshold: nil,
      schedulers: 4,
      load: 0.7,
      load_threshold: 1.0,
      build_status: :available,
      provider_backends: [],
      cpu_snapshot: :unavailable,
      target: nil,
      sampled_at_ms: now_ms - 60_000
    }

    sampled = Dispatcher.maybe_choose_under_load(%State{}, [], fn state, _ -> state end, admission_probes_fun: fn -> probes end, now_ms: now_ms)
    assert %DateTime{} = sampled.dispatch_capacity_sample.observed_at
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(sampled))
    assert snapshot.observations.dispatch.age_ms >= 60_000
    assert snapshot.capacity.dispatch_observation == snapshot.observations.dispatch
    assert snapshot.capacity.load == 0.7
    missing = Dispatcher.maybe_choose_under_load(%State{}, [], fn state, _ -> state end, admission_probes_fun: fn -> %{probes | load: :unavailable, sampled_at_ms: nil} end, now_ms: now_ms)
    assert missing.dispatch_capacity_sample.observed_at == nil
    assert StatusObservation.sample_observed_at(%{}) == nil
  end

  test "fresh CLI and web show the same capacity, ages and daemon retry scope" do
    failure = DateTime.add(DateTime.utc_now(), -80, :second)
    issue = %Issue{id: "44", identifier: "44", state: "in-progress", title: "Retry"}

    state = %State{
      max_concurrent_agents: 6,
      last_polled_issues: %{issue.id => issue},
      retry_attempts: %{issue.id => %{identifier: issue.identifier, attempt: 2, due_at_ms: System.monotonic_time(:millisecond) + 5_000, last_failure_at: failure, error: "startup failed"}}
    }

    input = StatusReport.snapshot_input(state)
    snapshot = StatusReport.snapshot_payload(input)
    server = self()
    on_exit(fn -> SnapshotStore.forget(server) end)
    :ok = SnapshotStore.publish(server, snapshot, input)
    {:ok, cli, freshness} = StatusReport.fleet_view(server, 5_000, fleet_rows?: true)
    payload = Presenter.state_payload(server, 5_000)
    assert payload.capacity.max == cli.capacity.max
    assert payload.capacity.observed_at == cli.capacity.observed_at
    assert payload.capacity.age_ms >= cli.capacity.age_ms
    assert payload.snapshot_freshness.status == :current
    assert payload.observations.fleet.observed_at == cli.observations.fleet.observed_at
    assert [retry] = payload.retrying
    assert retry.observed_at == DateTime.to_iso8601(failure)
    assert retry.age_ms >= 80_000
    assert retry.retry_scope == "since daemon start #{DateTime.to_iso8601(Boot.started_at())}"
    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:ok, cli, freshness}) end)
    assert output =~ "FLEET SNAPSHOT 0s old"
    assert output =~ "CAPACITY OBSERVATION 0s old"
    assert output =~ "AGENTS 0/6"
    assert output =~ "80s old; since daemon start"
    agents = capture_io(fn -> AgentControlCLI.agents(fleet_view: {:ok, cli, freshness}) end)
    assert agents =~ "FLEET SNAPSHOT 0s old"
    assert agents =~ "80s old; since daemon start"
    capacity_html = render_component(&CapacityControl.capacity_control/1, capacity: CapacityPresenter.present(payload.capacity), writable: false, input: "", feedback: nil)
    assert capacity_html =~ "maximum 6"
    assert capacity_html =~ "0s old"
    overview = render_component(&Overview.fleet_overview/1, fleet: payload, filters: MapSet.new([:all]))
    assert overview =~ "Fleet snapshot 0s old"
    table = render_component(&FleetTable.fleet_table/1, fleet: payload, now: DateTime.utc_now())
    assert table =~ "80s old; since daemon start"
  end

  test "missing observations and unavailable snapshots cannot masquerade as zero age or capacity" do
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(%State{}))
    assert snapshot.observations.dispatch == %{observed_at: nil, age_ms: nil}
    assert snapshot.observations.per_ticket == %{observed_at: nil, age_ms: nil}
    assert StatusObservation.label(snapshot.observations.dispatch) == "age unavailable"
    assert StatusObservation.label(%{observed_at: "invalid", age_ms: nil}) == "age unavailable"
    assert StatusObservation.observation("invalid", DateTime.utc_now()) == %{observed_at: nil, age_ms: nil}
    assert StatusObservation.observation(DateTime.add(DateTime.utc_now(), 10), DateTime.utc_now()).age_ms == 0
    assert StatusObservation.refresh(%{capacity: nil}) == %{capacity: nil}
    output = capture_io(fn -> AgentControlCLI.status(fleet_view: {:error, :unavailable}) end)
    assert output =~ "orchestrator is not running"
    refute output =~ "AGENTS 0/"
    absent = Presenter.state_payload(:missing_status_read_model, 50)
    assert absent.error.code == "orchestrator_unavailable"
    refute Map.has_key?(absent, :capacity)
  end
end
