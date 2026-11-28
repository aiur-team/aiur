defmodule Aiur.Events.GithubCIPoller.CancelledRunTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.GithubCIPoller.CancelledRun

  test "recognizes the incident's cancelled jobs alongside successful and skipped jobs" do
    incident_jobs =
      [
        %{"name" => "changes", "conclusion" => "success"},
        %{"name" => "soak", "conclusion" => "skipped"},
        %{"name" => "quarantined tests (non-blocking)", "conclusion" => "skipped"}
      ] ++
        Enum.map(1..27, &%{"name" => "test (#{&1}/27)", "conclusion" => "cancelled"}) ++
        [
          %{"name" => "ci gate", "conclusion" => "failure"}
        ]

    assert CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "cancelled"}, incident_jobs)
    assert CancelledRun.cancelled?(%{"event" => "pull_request"}, incident_jobs)
  end

  test "preserves real upstream failures while recognizing wholly cancelled jobs" do
    gate_failure = [
      %{"name" => "test", "conclusion" => "cancelled"},
      %{"name" => "lint", "conclusion" => "cancelled"},
      %{"name" => "ci gate", "conclusion" => "failure"}
    ]

    assert CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "failure"}, gate_failure)
    assert CancelledRun.cancelled?(%{"event" => "pull_request"}, gate_failure)

    superseded = Enum.map(gate_failure, &Map.put(&1, "conclusion", "cancelled"))
    assert CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "cancelled"}, superseded)

    mixed = List.replace_at(gate_failure, 1, %{"name" => "lint", "conclusion" => "failure"})
    refute CancelledRun.cancelled?(%{"event" => "merge_group", "conclusion" => "failure"}, mixed)

    real_failure_with_cancelled = [
      %{"name" => "test", "conclusion" => "cancelled"},
      %{"name" => "lint", "conclusion" => "timed_out"},
      %{"name" => "ci gate", "conclusion" => "failure"}
    ]

    refute CancelledRun.cancelled?(%{"event" => "merge_group"}, real_failure_with_cancelled)
  end

  # open-game-maker run 44060173589: every job was cancelled and the aggregate
  # `required` job failed only because of them. Two reworks sent the worker
  # non-failures before it ended in agent:error.
  test "an aggregate gate of any name that failed after its jobs were cancelled is a cancelled run" do
    jobs = [
      %{"name" => "detect changes", "conclusion" => "success", "started_at" => "2026-11-17T09:56:32Z", "completed_at" => "2026-11-17T09:56:40Z"},
      %{"name" => "ops shell tests", "conclusion" => "cancelled", "started_at" => "2026-11-17T09:56:32Z", "completed_at" => "2026-11-17T09:56:46Z"},
      %{"name" => "workspace", "conclusion" => "cancelled", "started_at" => "2026-11-17T09:56:43Z", "completed_at" => "2026-11-17T10:01:44Z"},
      %{"name" => "browser tests", "conclusion" => "cancelled", "started_at" => "2026-11-17T09:56:44Z", "completed_at" => "2026-11-17T10:01:44Z"},
      %{"name" => "required", "conclusion" => "failure", "started_at" => "2026-11-17T10:01:47Z", "completed_at" => "2026-11-17T10:01:53Z"}
    ]

    assert CancelledRun.cancelled?(%{"event" => "pull_request"}, jobs)

    # A job that fails on its own starts before the cancellations it causes.
    fail_fast = List.replace_at(jobs, 2, %{"name" => "workspace", "conclusion" => "failure", "started_at" => "2026-11-17T09:56:43Z", "completed_at" => "2026-11-17T09:58:00Z"})
    refute CancelledRun.cancelled?(%{"event" => "pull_request"}, fail_fast)

    # Without timestamps a failed job is never taken for a gate.
    untimed = Enum.map(jobs, &Map.drop(&1, ["started_at", "completed_at"]))
    refute CancelledRun.cancelled?(%{"event" => "pull_request"}, untimed)
  end
end
