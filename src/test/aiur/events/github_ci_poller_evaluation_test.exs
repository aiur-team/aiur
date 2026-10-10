defmodule Aiur.Events.GithubCIPollerEvaluationTest do
  use Aiur.TestSupport
  import Aiur.TestSupport.CIPollerFixture

  alias Aiur.Events.GithubCIPoller

  setup :ci_poller_env

  test "ready PR requires every required check to run successfully on the current head" do
    required = [%{name: "lint", app_id: 15_368}, %{name: "test", app_id: 15_368}]
    lint = %{"name" => "lint", "status" => "completed", "conclusion" => "success", "app" => %{"id" => 15_368}}
    test = %{lint | "name" => "test"}
    pr = %{"number" => 71, "head" => pr_head("aiur/42", "current-head"), "base" => %{"ref" => "main"}, "draft" => false}

    for checks <- [[lint], [lint, %{test | "conclusion" => "skipped"}], [lint, %{test | "app" => %{"id" => 1}}]] do
      batch = %{"42" => %{pull_request: pr, check_runs: checks, commit_status: %{"statuses" => []}}}

      assert {:ok, %{results: [%{decision: :pending, pending_reason: :required_checks_incomplete}]}} =
               poll(["42"], ci_batch: batch, required_check_fetcher: fn _ -> {:ok, required} end)
    end

    batch = %{"42" => %{pull_request: pr, check_runs: [lint, test], commit_status: %{"statuses" => []}}}

    assert {:ok, %{results: [%{decision: :passed, head_sha: "current-head"}]}} =
             poll(["42"], ci_batch: batch, required_check_fetcher: fn _ -> {:ok, required} end)

    assert {:ok, %{results: [%{decision: :pending, pending_reason: :required_checks_unavailable}]}} =
             poll(["42"], ci_batch: batch, required_check_fetcher: fn _ -> {:error, :denied} end)
  end

  test "returns pending for no observed checks or in-progress work" do
    assert %{decision: :pending, failures: []} = GithubCIPoller.evaluate_for_test([], %{"statuses" => []})

    assert %{decision: :pending, failures: []} =
             GithubCIPoller.evaluate_for_test(
               [%{"name" => "test", "status" => "in_progress", "conclusion" => nil}],
               %{"statuses" => []}
             )
  end

  test "uses the combined-status aggregate when contexts are absent" do
    assert %{decision: :passed, failures: []} =
             GithubCIPoller.evaluate_for_test([], %{"state" => "success", "statuses" => []})

    assert %{
             decision: :failed,
             failures: [%{name: "combined commit status", result: "failure"}]
           } = GithubCIPoller.evaluate_for_test([], %{"state" => "failure", "statuses" => []})

    assert %{decision: :pending, failures: []} =
             GithubCIPoller.evaluate_for_test([], %{"state" => "pending", "statuses" => []})
  end

  test "reports a test-only check failure for agent judgment" do
    assert %{
             decision: :failed,
             failures: [
               %{
                 name: "test",
                 kind: "check_run",
                 result: "failure",
                 excerpt: "expected green test suite"
               }
             ]
           } =
             GithubCIPoller.evaluate_for_test(
               [
                 %{
                   "name" => "test",
                   "status" => "completed",
                   "conclusion" => "failure",
                   "output" => %{"summary" => "expected green test suite"}
                 }
               ],
               %{"statuses" => []}
             )
  end

  test "ignores explicitly non-blocking check failures" do
    check_runs = [
      %{"name" => "test", "status" => "completed", "conclusion" => "success"},
      %{
        "name" => "quarantined tests (non-blocking)",
        "status" => "completed",
        "conclusion" => "failure"
      },
      %{"name" => "advisory scan (non-blocking)", "status" => "in_progress", "conclusion" => nil}
    ]

    assert %{decision: :passed, failures: []} =
             GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
  end

  # #2337 cause 4: a head sha carries check runs from both a superseded run and
  # the current run of the same workflow. A superseded run's failure is not a
  # failure of the head — the gate must consider the latest run per
  # (workflow, name). GitHub re-runs of the same workflow reuse the
  # `check_suite.id`, so same-suite runs are provably the same workflow.
  describe "superseded runs on the same head sha" do
    test "passes when the latest run per (workflow, name) is green despite an older failed run" do
      check_runs = [
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-22T20:00:00Z"},
        %{"name" => "coverage (2/4)", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-22T20:00:00Z"},
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "success", "started_at" => "2026-08-22T21:00:00Z"},
        %{"name" => "coverage (2/4)", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "success", "started_at" => "2026-08-22T21:00:00Z"}
      ]

      assert %{decision: :passed, failures: []} =
               GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
    end

    test "fails when the latest run on a (workflow, name) is itself failed" do
      check_runs = [
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "success", "started_at" => "2026-08-22T20:00:00Z"},
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-22T21:00:00Z"}
      ]

      assert %{decision: :failed} =
               GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
    end

    test "waits when the latest run is still in progress" do
      check_runs = [
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-22T20:00:00Z"},
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "in_progress", "conclusion" => nil, "started_at" => "2026-08-22T21:00:00Z"}
      ]

      assert %{decision: :pending, pending_reason: :check_runs_incomplete} =
               GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
    end

    test "does not collapse same-named runs from different workflows (different check suites)" do
      # ci.yml's `build` and streamdeck-package.yml's `build` land on one head
      # sha under distinct check suites. The failing required `build` must not
      # be dropped by the later-starting green one from the other workflow —
      # a gate that reports green on a red required check is the failure this
      # scoping exists to prevent.
      check_runs = [
        %{"name" => "build", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-23T01:41:39Z"},
        %{"name" => "build", "check_suite_id" => 88_376_212_345, "status" => "completed", "conclusion" => "success", "started_at" => "2026-08-23T01:42:00Z"}
      ]

      assert %{decision: :failed, failures: [%{name: "build"}]} =
               GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
    end

    test "never collapses runs that carry no check-suite identity" do
      # A run with no suite id is scoped by its own id, so a same-named failure
      # is never dropped in favor of a later green run of unknown provenance.
      check_runs = [
        %{"id" => 1, "name" => "test", "status" => "completed", "conclusion" => "failure", "started_at" => "2026-08-22T20:00:00Z"},
        %{"id" => 2, "name" => "test", "status" => "completed", "conclusion" => "success", "started_at" => "2026-08-22T21:00:00Z"}
      ]

      assert %{decision: :failed, failures: [%{name: "test"}]} =
               GithubCIPoller.evaluate_for_test(check_runs, %{"state" => "pending", "statuses" => []})
    end

    test "recency by completed_at, not list order, when started_at is absent" do
      # #2346 review: the previous fixture listed the success last, so a
      # last-listed-wins implementation passed vacuously. The failure has the
      # later completed_at; whichever order the list arrives in, recency must
      # keep the failure, not the last-listed run.
      success =
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-22T20:00:00Z"}

      failure =
        %{"name" => "test", "check_suite_id" => 88_376_209_394, "status" => "completed", "conclusion" => "failure", "completed_at" => "2026-08-22T21:00:00Z"}

      assert %{decision: :failed} =
               GithubCIPoller.evaluate_for_test([success, failure], %{"state" => "pending", "statuses" => []})

      assert %{decision: :failed} =
               GithubCIPoller.evaluate_for_test([failure, success], %{"state" => "pending", "statuses" => []})
    end
  end

  test "waits for every check before reporting the complete failure set" do
    partial_snapshot = [
      %{"name" => "lint", "status" => "completed", "conclusion" => "failure"},
      %{"name" => "test", "status" => "in_progress", "conclusion" => nil},
      %{"name" => "dialyzer", "status" => "queued", "conclusion" => nil}
    ]

    assert %{
             decision: :pending,
             pending_reason: :check_runs_incomplete,
             failures: [%{name: "lint", result: "failure"}]
           } = GithubCIPoller.evaluate_for_test(partial_snapshot, %{"statuses" => []})

    terminal_snapshot = [
      %{"name" => "dialyzer", "status" => "completed", "conclusion" => "success"},
      %{"name" => "test", "status" => "completed", "conclusion" => "timed_out"},
      %{"name" => "lint", "status" => "completed", "conclusion" => "failure"}
    ]

    assert %{
             decision: :failed,
             failures: [
               %{name: "test", result: "timed_out"},
               %{name: "lint", result: "failure"}
             ]
           } = GithubCIPoller.evaluate_for_test(terminal_snapshot, %{"statuses" => []})
  end

  test "treats cancelled and stale checks as replacement work instead of code failures" do
    for conclusion <- ["cancelled", "stale"] do
      assert %{
               decision: :pending,
               pending_reason: :check_runs_incomplete,
               failures: []
             } =
               GithubCIPoller.evaluate_for_test(
                 [%{"name" => "test", "status" => "completed", "conclusion" => conclusion}],
                 %{"statuses" => []}
               )
    end
  end

  test "does not suppress a test-only check failure" do
    assert %{
             decision: :failed,
             failures: [%{name: "test", kind: "check_run", result: "failure"}]
           } =
             GithubCIPoller.evaluate_for_test(
               [
                 %{"name" => "test", "status" => "completed", "conclusion" => "failure"},
                 %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
               ],
               %{"state" => "pending", "total_count" => 0, "statuses" => []}
             )
  end
end
