defmodule Aiur.Orchestrator.OptimisticTelemetryTest do
  use Aiur.TestSupport
  alias Aiur.Orchestrator.OptimisticLedger
  alias Aiur.TestCleanup

  setup do
    :ok = Supervisor.terminate_child(Aiur.Supervisor, OptimisticLedger)
    on_exit(fn -> Supervisor.restart_child(Aiur.Supervisor, OptimisticLedger) end)
    path = Path.join(System.tmp_dir!(), "optimistic-telemetry-#{System.unique_integer([:positive])}/starts.json")
    on_exit(fn -> TestCleanup.rm_rf!(Path.dirname(path)) end)
    owner = self()
    previous = Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn _, attrs, opts -> send(owner, {:point, attrs, opts}) end)
    on_exit(fn -> if previous, do: Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, previous), else: Application.delete_env(:aiur, :run_telemetry_lifecycle_recorder) end)
    start_supervised!({OptimisticLedger, path: path})
    :ok = OptimisticLedger.record_start("10", %{attempt_id: "attempt", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "12"}]})
    :ok
  end

  test "conflict reports and pushes persist and emit once despite replay" do
    sha = String.duplicate("a", 40)
    assert :ok = OptimisticLedger.record_push("10", "12", sha)
    assert :ok = OptimisticLedger.record_push("10", "12", sha)
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, true, true)
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, true, true)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["pushes_absorbed"] == 1
    assert row["counters"]["integrations_conflict"] == 1
    assert row["counters"]["non_ff_pushes"] == 1
    assert_received {:point, %{event: "blocker_push", blocker: "12"}, _}
    assert_received {:point, %{event: "blocker_integrate", outcome: "conflict", non_ff: true}, _}
    refute_received {:point, _, _}
  end

  test "unknown blockers, invalid evidence and absent tickets produce no integration" do
    sha = String.duplicate("a", 40)
    assert :ok = OptimisticLedger.record_integration("10", "other", sha, false, false)
    assert :ok = OptimisticLedger.record_integration("10", "12", "invalid", false, false)
    assert :ok = OptimisticLedger.record_integration("absent", "12", sha, false, false)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["integrations_clean"] == 0
    refute_received {:point, _, _}
  end

  test "a clean retry of a conflicting head retains both outcomes" do
    sha = String.duplicate("b", 40)
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, true, false)
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, false, false)
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, false, false)
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["counters"]["integrations_conflict"] == 1
    assert row["counters"]["integrations_clean"] == 1
    assert_received {:point, %{outcome: "conflict", event_key: conflict_key}, _}
    assert_received {:point, %{outcome: "clean", event_key: clean_key}, _}
    assert conflict_key != clean_key
    assert :ok = OptimisticLedger.record_integration("10", "12", sha, false, true)
    assert {:ok, corrected} = OptimisticLedger.get("10")
    assert corrected["counters"]["integrations_clean"] == 2
    assert corrected["counters"]["non_ff_pushes"] == 1
    assert_received {:point, %{outcome: "clean", non_ff: true, event_key: corrected_key}, _}
    assert corrected_key != clean_key
    refute_received {:point, _, _}
  end

  test "park resume and merged outcome carry the persisted attempt and head start" do
    assert :ok = OptimisticLedger.update_blocker("10", "12", %{merged_at_ms: 10_800_100, failed_cause: "pr_closed_unmerged"})
    assert :ok = OptimisticLedger.begin_park("10", "12", :pr_closed_unmerged, 200)
    assert :ok = OptimisticLedger.begin_park("10", "12", :pr_closed_unmerged, 200)
    assert :ok = OptimisticLedger.resume_park("10", 300)
    assert :ok = OptimisticLedger.close("10", :merged, 10_900_100)
    assert :ok = OptimisticLedger.close("10", :merged, 10_900_100)
    assert_received {:point, %{event: "optimistic_park", blocker: "12", cause: "pr_closed_unmerged"}, [timestamp: ~U[1970-01-01 00:00:00.200Z]]}
    assert_received {:point, %{event: "optimistic_resume"}, _}
    assert_received {:point, %{event: "optimistic_outcome", attempt_id: "attempt", outcome: "merged_after_redo", head_start_ms: 10_800_000, start_trigger: "pr_opened"}, _}
    refute_received {:point, _, _}
  end

  test "park records its triggering blocker rather than an older blocker failure" do
    attrs = %{attempt_id: "multi", start_trigger: :pr_opened, started_at_ms: 300, blockers: [%{"id" => "12", "failed_cause" => "agent_error"}, %{"id" => "13"}]}
    assert :ok = OptimisticLedger.record_start("10", attrs)
    assert :ok = OptimisticLedger.begin_park("10", "13", :pr_closed_unmerged, 400)
    assert_received {:point, %{event: "optimistic_park", blocker: "13", cause: "pr_closed_unmerged"}, _}
    refute_received {:point, _, _}
  end

  test "a restarted attempt preserves redo and the original optimistic start" do
    assert :ok = OptimisticLedger.bump("10", :parks, 1)
    assert :ok = OptimisticLedger.record_start("10", %{attempt_id: "retry", start_trigger: :pr_opened, started_at_ms: 500, blockers: [%{"id" => "12", "merged_at_ms" => 1000}]})
    assert :ok = OptimisticLedger.record_blocker_merge("12", 1000)
    assert :ok = OptimisticLedger.close("10", :merged, 2000)
    assert_received {:point, %{event: "optimistic_outcome", attempt_id: "retry", outcome: "merged_after_redo", head_start_ms: 900}, _}
    refute_received {:point, _, _}
  end

  test "a merge correction at the same timestamp keeps both outcome identities" do
    assert :ok = OptimisticLedger.close("10", :discarded, 200)
    assert :ok = OptimisticLedger.close("10", :merged, 200)
    assert_received {:point, %{event: "optimistic_outcome", outcome: "discarded", event_key: discarded_key}, _}
    assert_received {:point, %{event: "optimistic_outcome", outcome: "merged", event_key: merged_key}, _}
    assert discarded_key != merged_key
    assert {:ok, row} = OptimisticLedger.get("10")
    assert row["outcome"] == "merged"
  end

  test "head start floors at zero and missing merge evidence remains unavailable" do
    assert :ok = OptimisticLedger.update_blocker("10", "12", %{merged_at_ms: 50})
    assert :ok = OptimisticLedger.close("10", :merged, 200)
    assert_received {:point, %{event: "optimistic_outcome", head_start_ms: 0}, _}
    assert :ok = OptimisticLedger.record_start("11", %{attempt_id: "missing", start_trigger: :pr_opened, started_at_ms: 100, blockers: [%{"id" => "12"}]})
    assert :ok = OptimisticLedger.close("11", :merged, 200)
    assert_received {:point, attrs, _}
    assert attrs.event == "optimistic_outcome"
    refute Map.has_key?(attrs, :head_start_ms)
  end
end
