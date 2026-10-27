defmodule Aiur.ExecutorSweep.LatestChecksTest do
  use ExUnit.Case, async: true

  alias Aiur.ExecutorSweep.{Checks, CiObservation}

  test "approved PR findings use the latest same-name run and identify a failing run" do
    now = DateTime.utc_now()
    older = DateTime.to_iso8601(DateTime.add(now, -120, :second))
    newer = DateTime.to_iso8601(DateTime.add(now, -60, :second))

    pr = %{
      number: 5733,
      issue_number: 5847,
      state: "open",
      review_decision: "APPROVED",
      head_sha: "head-sha",
      approved_head_sha: "head-sha",
      in_merge_queue: false,
      auto_merge: true
    }

    ci = %{
      pr_number: 5733,
      head_sha: "head-sha",
      observed_at_ms: DateTime.to_unix(now, :millisecond),
      decision: :passed,
      check_runs: [
        %{"id" => 701, "name" => "pr body", "conclusion" => "failure", "started_at" => older},
        %{"id" => 702, "name" => "pr body", "conclusion" => "success", "started_at" => newer}
      ]
    }

    observed_pr = CiObservation.attach(pr, [ci])
    snapshot = %{pull_requests: [observed_pr], github_cache_ages: %{pull_requests: %{5733 => 0}}}

    refute Enum.any?(Checks.all(snapshot, now), &(&1.kind == "approved_pr_red"))

    failed_run = %{"id" => 703, "name" => "pr body", "conclusion" => "failure", "started_at" => newer}
    failed_ci = put_in(ci.check_runs, [hd(ci.check_runs), failed_run])
    failed_pr = CiObservation.attach(pr, [failed_ci])
    [finding] = Enum.filter(Checks.all(put_in(snapshot.pull_requests, [failed_pr]), now), &(&1.kind == "approved_pr_red"))

    assert finding.message =~ "#703"
  end
end
