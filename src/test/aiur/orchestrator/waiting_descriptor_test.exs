defmodule Aiur.Orchestrator.WaitingDescriptorTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Aiur.{AgentControlCLI, AgentQueueItem, Issue}
  alias Aiur.Orchestrator.{AutoResume, LifecycleFence, RetryEngine, Slots, SnapshotStore, State, StatusReport, WaitingReason}
  alias Aiur.Workspace.Ownership
  alias AiurWeb.Presenter

  test "every current WaitingReason has the owner that can clear it" do
    owners = %{
      waiting_for_human: "Executor",
      waiting_for_supervisor: "Executor",
      waiting_for_dependency: "DispatchPolicy",
      waiting_for_ci: "CiLifecycle",
      waiting_for_review: "Executor",
      paused: "PauseResume",
      run_paused: "PauseResume",
      awaiting_dispatch: "Dispatcher",
      paused_operator: "PauseResume",
      paused_transient: "AutoResume",
      provider_limited: "RateLimitFallback",
      latched_lifetime: "Dispatcher",
      tracker_unavailable: "Dispatcher",
      backing_off: "RetryEngine",
      unresponsive: "RuntimeWatchdog",
      claim_released: "AutoResume",
      orphaned_claim: "StartupClaimReconciler",
      stale_claim: "Reconciler",
      workspace_ownership_waiting: "Workspace.Ownership",
      active: "AgentRunner"
    }

    {:ok, types} = Code.Typespec.fetch_types(WaitingReason)
    {:type, {:t, ast, []}} = Enum.find(types, fn {_visibility, {name, _, _}} -> name == :t end)
    {:type, _, :union, atoms} = ast
    assert Enum.sort(Enum.map(atoms, fn {:atom, _, reason} -> reason end)) == Enum.sort(Map.keys(owners))

    for {reason, owner} <- owners do
      assert %{reason: ^reason, owner: ^owner} = WaitingReason.describe(reason, %{})
    end
  end

  test "retry cause and failure time reach CLI rows, snapshot rows and JSON" do
    since = DateTime.add(DateTime.utc_now(), -45, :second)
    retry = %{identifier: "wait-retry", attempt: 1, due_at_ms: System.monotonic_time(:millisecond) + 1_000, error: "provider unavailable", last_failure_at: since}
    state = %State{retry_attempts: %{"wait-retry" => retry}}
    [row] = StatusReport.agent_statuses(state)
    snapshot = StatusReport.snapshot_payload(StatusReport.snapshot_input(state))
    [snapshot_row] = snapshot.retrying

    for waiting <- [row.waiting, snapshot_row.waiting] do
      assert waiting.reason == :backing_off
      assert waiting.owner == "RetryEngine"
      assert waiting.cause == "provider unavailable"
      assert waiting.since == since
      assert waiting.age_ms >= 45_000
    end

    output = capture_io(fn -> AgentControlCLI.agents(fleet_view: fleet(snapshot)) end)
    assert output =~ ~r/· backing_off · RetryEngine · \d+s/
    assert Jason.decode!(Jason.encode!(snapshot_row.waiting))["since"] == DateTime.to_iso8601(since)
  end

  test "missing timestamp renders since unknown and encodes JSON null through the status API" do
    retry = %{identifier: "wait-unknown", attempt: 1, due_at_ms: System.monotonic_time(:millisecond), error: nil}
    snapshot = StatusReport.snapshot_payload(%State{retry_attempts: %{"wait-unknown" => retry}})
    [row] = snapshot.retrying
    assert row.waiting.cause == :unknown
    assert row.waiting.since == nil
    assert row.waiting.age_ms == nil
    output = capture_io(fn -> AgentControlCLI.agents(fleet_view: fleet(snapshot)) end)
    assert output =~ "· RetryEngine · since unknown"

    server = start_supervised!({Agent, fn -> snapshot end})
    :ok = SnapshotStore.publish(server, snapshot)
    on_exit(fn -> SnapshotStore.forget(server) end)
    payload = Presenter.state_payload(server, 100, include_auxiliary?: false)
    [json_row] = Jason.decode!(Jason.encode!(payload))["retrying"]
    assert json_row["waiting"]["since"] == nil
    assert json_row["waiting"]["age_ms"] == nil
    assert json_row["waiting"]["owner"] == "RetryEngine"
    snapshot = Map.put(snapshot, :statuses, StatusReport.agent_statuses(%State{retry_attempts: %{"wait-unknown" => retry}}))
    status = capture_io(fn -> AgentControlCLI.status(fleet_view: fleet(snapshot)) end)
    assert status =~ "· backing_off · RetryEngine · since unknown"
    watch = capture_io(fn -> AgentControlCLI.watch(fleet_view: fleet(snapshot), mode: :full) end)
    assert watch =~ "· backing_off · RetryEngine · since unknown"
  end

  test "rework waits name the lifecycle fence until provider delivery closes it" do
    issue = %Issue{id: "wait-fence", identifier: "wait-fence", state: "rework"}
    entry = %{identifier: issue.identifier, issue: issue, session_id: "session", started_at: DateTime.utc_now(), control: %{status: :working}}
    item = %AgentQueueItem{id: 771, target_issue_identifier: issue.identifier, category: :operator_message}
    state = LifecycleFence.protect_queued_item(%State{running: %{issue.id => entry}}, issue.identifier, item)
    assert Map.has_key?(state.running[issue.id], :lifecycle_fence)
    [row] = StatusReport.agent_statuses(state)
    assert row.waiting_reason == :active
    assert row.waiting.reason == :active
    assert row.waiting.owner == "LifecycleFence"
    assert row.waiting.cause == :provider_delivery_pending
    assert row.waiting.since == state.running[issue.id].lifecycle_fence.opened_at
    assert is_integer(row.waiting.age_ms)
    [snapshot_row] = StatusReport.snapshot_payload(state).running
    assert snapshot_row.waiting.owner == "LifecycleFence"
    output = capture_io(fn -> AgentControlCLI.agents(fleet_view: fleet(StatusReport.snapshot_payload(state))) end)
    assert output =~ ~r/· active · LifecycleFence · \d+s/
    closed = LifecycleFence.acknowledge_provider_delivery(state, item)
    [resumed] = StatusReport.agent_statuses(closed)
    assert resumed.waiting_reason == :active
    assert resumed.waiting.owner == "AgentRunner"
  end

  test "workspace waiting after runtime loss releases capacity and retains recorded reason and time" do
    issue = %Issue{id: "wait-workspace", identifier: "wait-workspace", state: "todo"}
    entry = %{identifier: issue.identifier, issue: issue, control: %{status: :working}, started_at: DateTime.utc_now(), session_id: "session"}
    state = %State{last_polled_issues: %{issue.id => issue}, running: %{issue.id => entry}, max_concurrent_agents: 2}
    {:ok, lease} = Ownership.claim(issue.identifier)
    on_exit(fn -> Ownership.release(lease) end)
    waiting = RetryEngine.wait_for_workspace_ownership(state, issue.id, issue.identifier, :previous_session, {:bound, lease.guardian, lease.generation})
    since = waiting.dispatch_recovery.workspace_ownership.waits[issue.identifier].since
    assert %DateTime{} = since
    assert Slots.available_slots(waiting) == Slots.available_slots(state) + 1
    [row] = StatusReport.agent_statuses(waiting)
    assert row.waiting_reason == :workspace_ownership_waiting
    assert row.waiting.owner == "Workspace.Ownership"
    assert row.waiting.cause == :previous_session
    assert row.waiting.since == since
    [snapshot_row] = StatusReport.snapshot_payload(waiting).idle
    assert snapshot_row.waiting.since == since
    output = capture_io(fn -> AgentControlCLI.agents(fleet_view: fleet(StatusReport.snapshot_payload(waiting))) end)
    assert output =~ ~r/· workspace_ownership_waiting · Workspace.Ownership · \d+s/
  end

  test "monotonic holds, paused episodes and claim releases preserve their own clocks" do
    issue = %Issue{id: "wait-hold", identifier: "wait-hold", state: "todo"}
    hold = %{signal: :load, measured: 8, threshold: 4, detail: "host load", held_since_ms: System.monotonic_time(:millisecond) - 12_000}
    state = %State{last_polled_issues: %{issue.id => issue}, capacity_hold: hold}
    [row] = StatusReport.agent_statuses(state)
    assert row.waiting.owner == "Dispatcher"
    assert row.waiting.cause == "host load"
    assert row.waiting.age_ms >= 12_000
    assert row.waiting.age_ms < 30_000
    assert %DateTime{} = row.waiting.since

    since = DateTime.add(DateTime.utc_now(), -20, :second)
    paused = WaitingReason.attach(%{issue_id: issue.id, identifier: issue.identifier, waiting_reason: :paused, pause_reason: :operator_pause}, state, %{paused_at: since})
    assert paused.waiting.since == since
    assert paused.waiting.cause == :operator_pause
    released = %{state | released_claims: %{issue.id => %{cause: :worker_exit, released_at_ms: hold.held_since_ms}}}
    [row] = StatusReport.agent_statuses(released)
    assert row.waiting.reason == :claim_released
    assert row.waiting.cause == :worker_exit
    assert row.waiting.age_ms >= 12_000
  end

  test "pending fences preserve deactivated, human and paused waits and ignore empty fences" do
    issue = %Issue{id: "wait-fence-exclusions", identifier: "wait-fence-exclusions", state: "rework"}
    entry = %{identifier: issue.identifier, issue: issue, started_at: DateTime.utc_now(), session_id: "session", control: %{status: :working}}
    item = %AgentQueueItem{id: 772, target_issue_identifier: issue.identifier, category: :operator_message}
    protected = LifecycleFence.protect_queued_item(%State{running: %{issue.id => entry}}, issue.identifier, item)
    entry = protected.running[issue.id]

    for {control, pause, expected} <- [{:deactivated, nil, :active}, {:paused, :input_required, :waiting_for_human}, {:paused, :operator_pause, :paused}] do
      adjusted = %{entry | control: %{status: control}} |> Map.put(:paused_reason, pause)
      [row] = StatusReport.agent_statuses(%{protected | running: %{issue.id => adjusted}})
      assert row.waiting_reason == expected
      refute row.waiting.owner == "LifecycleFence"
    end

    empty = put_in(entry.lifecycle_fence.pending_item_ids, MapSet.new())
    [row] = StatusReport.agent_statuses(%{protected | running: %{issue.id => empty}})
    assert row.waiting_reason == :active
  end

  test "public waiting JSON keeps unsupported cause detail" do
    cause = {:provider_exit, 23}
    row = WaitingReason.attach(%{issue_id: "tuple", identifier: "tuple", waiting_reason: :backing_off, error: cause}, %State{})
    assert row.waiting.cause == cause
    json = row |> WaitingReason.public_wait() |> Jason.encode!() |> Jason.decode!()
    assert json["cause"] == "{:provider_exit, 23}"
  end

  test "idle transient recovery and label pauses report the same cause in both row paths" do
    issue = %Issue{id: "wait-transient", identifier: "wait-transient", state: "error"}
    state = AutoResume.schedule(%State{last_polled_issues: %{issue.id => issue}}, issue.id, :github_budget_hold)
    [status] = StatusReport.agent_statuses(state)
    [snapshot] = StatusReport.snapshot_payload(StatusReport.snapshot_input(state)).idle

    for row <- [status, snapshot] do
      assert row.waiting.reason == :paused_transient
      assert row.waiting.cause == :github_budget_hold
      assert %DateTime{} = row.waiting.since
      assert is_integer(row.waiting.age_ms)
    end

    issue = %{issue | paused: true}
    state = %{state | last_polled_issues: %{issue.id => issue}}
    [status] = StatusReport.agent_statuses(state)
    [snapshot] = StatusReport.snapshot_payload(state).idle

    for row <- [status, snapshot] do
      assert row.waiting.reason == :paused_operator
      assert row.waiting.cause == :label_override
      assert row.waiting.since == nil
    end
  end

  test "future and invalid timestamps never report negative or invented ages" do
    row = %{issue_id: "clock", identifier: "clock", waiting_reason: :backing_off}

    log =
      capture_log(fn ->
        result = WaitingReason.attach(Map.put(row, :last_failure_at, DateTime.add(DateTime.utc_now(), 60, :second)), %State{})
        assert result.waiting.age_ms == 0
      end)

    assert log =~ "clamping age"
    assert WaitingReason.attach(Map.put(row, :last_failure_at, "invalid"), %State{}).waiting.age_ms == nil
    iso = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.to_iso8601()
    assert WaitingReason.attach(Map.put(row, :last_failure_at, iso), %State{}).waiting.age_ms >= 10_000
  end

  test "collapsed waits name the collapse instead of borrowing a specific cause" do
    facts = %{
      error: "provider unavailable",
      pause_reason: :operator_pause,
      work_state: :working,
      blocked_by: [%{identifier: "1"}],
      dispatch_latch: {:lifetime, 3, 3},
      dispatch_hold_reason: :tracker_preflight,
      claim_release_cause: :worker_exit,
      auto_resume_cause: :github_budget_hold,
      hold_cause: "host load",
      ci_result: %{status: :failed}
    }

    for reason <- [:waiting_for_supervisor, :waiting_for_ci, :waiting_for_review, :orphaned_claim, :stale_claim] do
      assert WaitingReason.describe(reason, facts).cause == :unknown
      assert WaitingReason.describe(reason, %{}).cause == :unknown
    end
  end

  test "dependency and lifetime-latch waits render since unknown instead of another clock" do
    started = DateTime.add(DateTime.utc_now(), -300, :second)
    clocks = %{started_at: started, created_at: started, updated_at: started, paused_at: started, last_failure_at: started, last_codex_timestamp: started, released_at: started}
    issue = %Issue{id: "wait-dep", identifier: "wait-dep", state: "todo", blocked_by: [%{id: "b", identifier: "9", state: "todo", url: nil}], created_at: started, updated_at: started}
    state = %State{last_polled_issues: %{issue.id => issue}}
    [row] = StatusReport.agent_statuses(state)
    assert row.waiting_reason == :waiting_for_dependency

    hold = %{held_since_ms: System.monotonic_time(:millisecond) - 300_000, detail: "host load"}
    state = %{state | capacity_hold: hold, dispatch_hold: hold}

    for reason <- [:waiting_for_dependency, :latched_lifetime] do
      row = %{issue_id: issue.id, identifier: issue.identifier, waiting_reason: reason} |> Map.merge(clocks)
      attached = WaitingReason.attach(row, state, clocks)
      assert attached.waiting.since == nil
      assert attached.waiting.age_ms == nil
      assert WaitingReason.render_wait(attached) == " · #{reason} · #{attached.waiting.owner} · since unknown"
    end
  end

  defp fleet(snapshot), do: {:ok, snapshot, %{status: :current, age_seconds: 0}}
end
