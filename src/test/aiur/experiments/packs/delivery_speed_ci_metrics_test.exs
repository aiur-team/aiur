defmodule Aiur.Experiments.Packs.DeliverySpeedCiMetricsTest do
  use ExUnit.Case, async: true

  alias Aiur.Experiments.Packs.DeliverySpeed.Periods

  defp window do
    start = DateTime.new!(Date.add(Date.utc_today(), -1), ~T[00:00:00], "Etc/UTC")
    %{start: start, end: DateTime.add(start, 86_400, :second)}
  end

  defp timestamp(hour, minute \\ 0) do
    window().start
    |> DateTime.add(hour * 3_600 + minute * 60, :second)
    |> DateTime.to_iso8601()
  end

  test "CI failure rate counts decided PR runs and excludes cancelled runs" do
    runs =
      for id <- 1..12 do
        conclusion =
          cond do
            id <= 3 -> "failure"
            id <= 10 -> "success"
            true -> "cancelled"
          end

        %{"id" => id, "event" => "pull_request", "conclusion" => conclusion, "updated_at" => timestamp(12), "run_attempt" => 1}
      end

    {rows, 0} = Periods.observations("ci_run_failure_rate", %{ci_runs: runs}, window())
    assert length(rows) == 10
    assert Enum.sum(Enum.map(rows, & &1.value)) == 3
  end

  test "rerun rate records one binary unit for an attempt greater than one" do
    runs = [
      %{"id" => 1, "event" => "pull_request", "conclusion" => "success", "updated_at" => timestamp(12), "run_attempt" => 1},
      %{"id" => 2, "event" => "merge_group", "conclusion" => "failure", "updated_at" => timestamp(12), "run_attempt" => 2}
    ]

    {rows, 0} = Periods.observations("ci_rerun_rate", %{ci_runs: runs}, window())
    assert Enum.map(rows, & &1.value) == [0, 1]
  end

  test "merge-group failure rate filters out pull request runs" do
    runs = [
      %{"id" => 1, "event" => "pull_request", "conclusion" => "failure", "updated_at" => timestamp(12)},
      %{"id" => 2, "event" => "merge_group", "conclusion" => "success", "updated_at" => timestamp(12)}
    ]

    {rows, 0} = Periods.observations("merge_group_failure_rate", %{ci_runs: runs}, window())
    assert Enum.map(rows, &{&1.unit_id, &1.value}) == [{"run:2", 0}]
  end

  test "CI wall time and job queue wait are durations with invalid timestamps filtered" do
    runs = [
      %{"id" => 1, "event" => "pull_request", "conclusion" => "success", "run_started_at" => timestamp(10), "updated_at" => timestamp(10, 30)},
      %{"id" => 2, "event" => "pull_request", "conclusion" => "failure", "run_started_at" => nil, "updated_at" => timestamp(10, 30)}
    ]

    jobs = [
      %{"id" => 1, "name" => "test", "created_at" => timestamp(10), "started_at" => timestamp(10, 2)},
      %{"id" => 2, "name" => "test", "created_at" => timestamp(10), "started_at" => nil}
    ]

    {ci_rows, 1} = Periods.observations("pr_ci_wall_time", %{ci_runs: runs}, window())
    {job_rows, 1} = Periods.observations("ci_queue_wait", %{ci_jobs: jobs}, window())
    assert [%{value: 1_800_000}] = ci_rows
    assert [%{value: 120_000}] = job_rows
  end

  test "flake issues are counted in their creation day" do
    issues = [%{"number" => 1, "createdAt" => timestamp(12)}, %{"number" => 2, "createdAt" => timestamp(13)}]
    {rows, 0} = Periods.observations("flake_issues_filed", %{flake_issues: issues}, window())
    assert [%{unit_id: "day:" <> _, value: 2}] = Enum.filter(rows, &(&1.value == 2))
  end

  test "feature merge share has no row for a day with no merged PRs" do
    assert {[], 0} = Periods.observations("feature_merge_share", %{github_pulls: []}, window())
  end

  test "innocent dequeue requires the same head to be merged after removal" do
    pulls = [
      %{
        "number" => 1,
        "headRefOid" => "same",
        "mergedAt" => timestamp(12),
        "timelineItems" => %{"nodes" => [%{"__typename" => "RemovedFromMergeQueueEvent", "beforeCommit" => %{"oid" => "same"}, "reason" => "failed_checks", "createdAt" => timestamp(11)}]}
      },
      %{
        "number" => 2,
        "headRefOid" => "new",
        "mergedAt" => timestamp(13),
        "timelineItems" => %{"nodes" => [%{"__typename" => "RemovedFromMergeQueueEvent", "beforeCommit" => %{"oid" => "old"}, "reason" => "failed_checks", "createdAt" => timestamp(11)}]}
      }
    ]

    {rows, 0} = Periods.observations("innocent_dequeues", %{github_pulls: pulls, queue_removals: []}, window())
    assert Enum.map(rows, & &1.value) == [1, 0]
  end

  test "flaky failure rate uses only failed test jobs with journaled innocent evidence" do
    jobs = [
      %{"id" => 1, "run_id" => 91, "name" => "test (1/2)", "conclusion" => "failure", "completed_at" => timestamp(12)},
      %{"id" => 2, "run_id" => 92, "name" => "test (2/2)", "conclusion" => "failure", "completed_at" => timestamp(13)}
    ]

    evidence = [%{"job" => "test (1/2)", "run_url" => "https://github.com/o/r/actions/runs/91", "red_on_main" => true, "job_failure_set_complete" => true, "touched" => false}]
    runs = [%{"id" => 91, "event" => "merge_group"}, %{"id" => 92, "event" => "merge_group"}]

    assert {[%{value: 0.5, attrs: %{"innocent_failed_test_jobs" => 1, "failed_test_jobs" => 2}}], 0} =
             Periods.observations("flaky_failure_rate", %{ci_jobs: jobs, ci_runs: runs, flake_evidence: evidence}, window())
  end

  test "flaky failure rate excludes jobs with incomplete or mixed failure evidence" do
    jobs = [%{"id" => 1, "run_id" => 91, "name" => "test", "conclusion" => "failure", "completed_at" => timestamp(12)}]
    base_failure = %{"job" => "test", "run_url" => "https://github.com/o/r/actions/runs/91", "red_on_main" => true, "job_failure_set_complete" => true, "touched" => false}
    mixed_failure = Map.put(base_failure, "red_on_main", false)

    assert {[%{value: value, attrs: %{"innocent_failed_test_jobs" => 0, "failed_test_jobs" => 1}}], 0} =
             Periods.observations("flaky_failure_rate", %{ci_jobs: jobs, ci_runs: [%{"id" => 91, "event" => "merge_group"}], flake_evidence: [base_failure, mixed_failure]}, window())

    assert_in_delta value, 0.0, 1.0e-12
  end

  test "pull request failed jobs do not enter the merge-group flaky denominator" do
    jobs = [
      %{"id" => 1, "run_id" => 91, "name" => "test", "conclusion" => "failure", "completed_at" => timestamp(12)},
      %{"id" => 2, "run_id" => 92, "name" => "test", "conclusion" => "failure", "completed_at" => timestamp(13)}
    ]

    evidence = [%{"job" => "test", "run_url" => "https://github.com/o/r/actions/runs/92", "red_on_main" => true, "job_failure_set_complete" => true, "touched" => false}]
    runs = [%{"id" => 91, "event" => "pull_request"}, %{"id" => 92, "event" => "merge_group"}]

    assert {[%{value: 1.0, attrs: %{"innocent_failed_test_jobs" => 1, "failed_test_jobs" => 1}}], 0} =
             Periods.observations("flaky_failure_rate", %{ci_jobs: jobs, ci_runs: runs, flake_evidence: evidence}, window())
  end
end
