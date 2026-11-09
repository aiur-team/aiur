defmodule Aiur.Orchestrator.CiStatusProjectionTest do
  use Aiur.TestSupport

  import ExUnit.CaptureIO

  alias Aiur.ControlCLI.CiWait
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.Orchestrator.StatusReport.SnapshotPayload

  test "CI wait snapshot carries freshness for rows displayed by the CLI" do
    state = %Aiur.Orchestrator.State{
      ci_lifecycle: %{
        approved_heads: %{},
        passed_heads: %{},
        test_failure_heads: %{},
        base_repair_invalidations: %{},
        ci_observed_at_ms: %{"3864" => 1234},
        poll_cache: %{
          "3864" => %{tracker_state: "ci-wait", decision: :pending, pr_number: 42, recovery: "rerun_requested"}
        },
        rewakes: %{},
        parked_ready_alerts: nil
      }
    }

    snapshot = state |> StatusReport.snapshot_input() |> SnapshotPayload.snapshot_payload()

    assert [%{identifier: "3864", observed_at_ms: 1234}] = snapshot.ci_wait
    assert capture_io(fn -> CiWait.print(snapshot) end) =~ "CI WAIT 3864 PR #42: rerun_requested"
  end

  test "CI wait CLI omits human-review rows retained for the sweep" do
    rows = [
      %{identifier: "3864", pr_number: 42, tracker_state: "ci-wait", decision: :pending},
      %{identifier: "5636", pr_number: 77, tracker_state: "human-review", decision: :failed}
    ]

    assert capture_io(fn -> CiWait.print(%{ci_wait: rows}) end) == "CI WAIT 3864 PR #42: pending\n"
  end
end
