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
end
