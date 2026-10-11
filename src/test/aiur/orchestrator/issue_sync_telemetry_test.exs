defmodule Aiur.Orchestrator.IssueSyncTelemetryTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, Orchestrator, TrackerIdentity}
  alias Aiur.Orchestrator.{IssueSync, SnapshotStore, State}
  alias Aiur.RunTelemetry.{Sampler, UsageCapture}

  setup do
    keys = [:run_telemetry_lifecycle_recorder, :run_telemetry_usage_query]
    captured = Enum.map(keys, &{&1, Application.fetch_env(:aiur, &1)})
    on_exit(fn -> Aiur.TestSupport.restore_app_env(captured) end)
    parent = self()
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn :lifecycle, fields, _ -> send(parent, {:metric, fields}) end)
    :ok
  end

  test "two real polls record state change and blocker clearance" do
    issue = issue("poll-metric")
    blocker = %{id: "blocker", identifier: "11", state: "in-progress"}
    previous = %{issue | blocked_by: [blocker]}
    state = sync(%State{}, [previous])
    refute_received {:metric, %{event: "state_change"}}

    current = %{previous | state: "ci-wait", blocked_by: []}
    _state = sync(state, [current])

    assert_received {:metric, %{event: "state_change", from_state: "in-progress", to_state: "ci-wait"}}
    assert_received {:metric, %{event: "dependency_cleared", blocker: "11", cause: "removed"}}
  end

  test "active-only poll disappearance captures terminal usage off-path" do
    if is_nil(Process.whereis(UsageCapture)), do: start_supervised!({UsageCapture, []})
    tasks = Aiur.RunTelemetry.UsageTasks
    if is_nil(Process.whereis(tasks)), do: start_supervised!({Task.Supervisor, name: tasks})
    previous = issue(to_string(System.unique_integer([:positive])))
    identity = previous.tracker_identity
    parent = self()

    Application.put_env(:aiur, :run_telemetry_usage_query, fn %{tickets: [^identity]} ->
      send(parent, :usage_queried)

      %{
        totals: %{tokens: %{input: 120, output: 30, cached_input: 5}, money: %{{:provider_reported, "USD"} => Decimal.new("1.50")}},
        health: :healthy,
        coverage: %{selected_cells: 1, unknown_attribution: %{ticket: 0}, projection: %{partial_records: 0}}
      }
    end)

    state = sync(%State{}, [previous])
    refute_received :usage_queried
    state = sync(state, [], fn [_id] -> {:ok, [%{previous | state: "done"}]} end)

    for pid <- Task.Supervisor.children(tasks) do
      ref = Process.monitor(pid)
      receive_barrier({:DOWN, ^ref, :process, ^pid, _reason})
    end

    assert state.last_polled_issues == %{}
    assert_received :usage_queried
    assert_received {:metric, %{event: "ticket_usage", ticket: ticket, input_tokens: 120, output_tokens: 30, cached_tokens: 5, cost_amount: "1.50", cost_currency: "USD", coverage: "complete"}}
    assert ticket == previous.identifier
  end

  test "sampler reads the binding kind classified by the real dashboard facade" do
    key = :"metric_snapshot_#{System.unique_integer([:positive])}"
    snapshot = %{capacity: %{occupied: 4, configured: 4, max: 4, effective: 4, available: 0}, polling: %{}}
    :ok = SnapshotStore.publish(key, snapshot)
    on_exit(fn -> SnapshotStore.forget(key) end)
    assert {:current, %{fleet_binding_kind: "config_cap"}, _freshness} = Orchestrator.dashboard_snapshot(key, 100)

    result =
      Sampler.sample_once(%{},
        process_table_fun: fn -> {:error, :reader_failed} end,
        entries_fun: fn -> [] end,
        daemon_pid: nil,
        operator_pid: nil,
        fd_headroom_fun: fn -> :unavailable end,
        system_ms_fun: fn -> 42 end,
        fleet_snapshot_fun: fn -> Orchestrator.dashboard_snapshot(key, 100) end,
        build_status_fun: fn -> %{enabled?: false} end
      )

    daemon = Enum.find(result.records, &(&1.actor == "_daemon"))
    assert daemon.fleet_binding_kind == "config_cap"
  end

  defp sync(state, issues, fetch \\ fn _ -> {:ok, []} end) do
    IssueSync.sync_polled_issue_state(state, issues, fetch, fn _, _ -> :ok end, MapSet.new(["done", "cancelled"]), fn _ -> :ok end, fn _, _ -> :ok end)
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: id,
      state: "in-progress",
      blocked_by: [],
      tracker_identity: %TrackerIdentity{status: :joinable, kind: :github, owner: "its-everdred", repository: "aiur", provider_id: "node-#{id}", identifier: id, reason: nil}
    }
  end
end
