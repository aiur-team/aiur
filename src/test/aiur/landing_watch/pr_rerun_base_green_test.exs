defmodule Aiur.LandingWatch.PrRerunBaseGreenTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{Journal, PrRerun, PrRerunClassifier}

  @started "2026-10-14T10:00:00Z"
  @started_ms 1_791_972_000_000

  test "a later passing base check refreshes an approved auto-merge PR while main stayed green" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "landing-base-green-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)

    history = [
      %{completed_at: @started_ms - 60_000, checks: [%{name: "audit", conclusion: "success"}]},
      %{completed_at: @started_ms + 60_000, checks: [%{name: "audit", conclusion: "success"}]}
    ]

    observation = %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: %{"enabledAt" => "2026-10-14T09:00:00Z"},
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false},
      reviews: [%{"commit" => %{"oid" => "head-sha"}}]
    }

    run = %{
      "run_id" => 99,
      "name" => "audit",
      "status" => "completed",
      "conclusion" => "failure",
      "started_at" => @started,
      "workflow_jobs" => [%{"id" => 7, "name" => "audit", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}]}]
    }

    opts = [
      actions_run_fun: fn 99, _ -> {:ok, %{"path" => ".github/workflows/ci.yml"}} end,
      workflow_definitions_fun: fn ".github/workflows/ci.yml", "main", _ -> {:ok, %{"audit" => %{"name" => "audit"}}} end,
      recent_main_failure_paths: [],
      known_failure_patterns: [],
      job_log_fun: fn _, _ -> {:ok, "unrecognized test failure"} end,
      main_history_fun: fn -> history end,
      ci_merges_fun: fn _ -> {:ok, [%{"pr" => 5913, "merged_at_ms" => @started_ms + 30_000, "paths" => ["src/mix.lock"]}]} end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/lib/aiur/feature.ex"]} end,
      base_branch: "main",
      rerun_fun: fn _, _ -> send(parent, :rerun) && {:ok, %{}} end,
      base_changes_fun: fn _head, "main", _ -> {:ok, ["README.md"]} end,
      refresh_observation_fun: fn 17, _ ->
        {:ok, %{"state" => "OPEN", "headRefOid" => "head-sha", "isDraft" => false, "reviewDecision" => "APPROVED", "mergeQueueEntry" => nil}}
      end,
      update_branch_fun: fn 17, "head-sha", _ -> send(parent, :updated) && {:ok, %{}} end,
      observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-head"}} end,
      approval_carry_classifier: fn _, _, _, _ -> :identical end,
      comment_fun: fn _, _, _ -> {:ok, %{}} end,
      rework_fun: fn _, failures, _ -> send(parent, {:rework, failures}) && :ok end,
      job_log_fun: fn _, _ -> {:ok, "unrecognized test failure"} end,
      journal_path: path,
      now_ms: @started_ms + 3_600_000
    ]

    assert {:ok, {:refresh, _}} = PrRerunClassifier.classify(observation, %{failures: [%{name: "audit"}]}, [run], opts)
    assert :ok = PrRerun.handle_failure(observation, %{failures: [%{name: "audit"}]}, [run], opts)
    assert_received :updated
    refute_received :rerun

    later_opts = Keyword.put(opts, :now_ms, @started_ms + 4_000_000)

    refreshed_observation = %{
      observation
      | head: "refreshed-head",
        raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "refreshed-head", "isDraft" => false},
        reviews: [%{"commit" => %{"oid" => "refreshed-head"}}]
    }

    assert :ok = PrRerun.handle_failure(refreshed_observation, %{failures: [%{name: "audit"}]}, [run], later_opts)
    refute_received :updated
    refute_received :rerun
    assert_received {:rework, [%{name: "audit"}]}
  end

  test "a green main check without a changed check input does not refresh a PR-caused test failure" do
    history = [
      %{completed_at: @started_ms - 60_000, checks: [%{name: "test", conclusion: "success"}]},
      %{completed_at: @started_ms + 60_000, checks: [%{name: "test", conclusion: "success"}]}
    ]

    run = %{
      "run_id" => nil,
      "name" => "test",
      "status" => "completed",
      "conclusion" => "failure",
      "started_at" => @started,
      "workflow_jobs" => [%{"name" => "test", "conclusion" => "failure"}]
    }

    assert {:ok, :rework} =
             PrRerunClassifier.classify(%{number: 18}, %{failures: [%{name: "test"}]}, [run],
               main_history_fun: fn -> history end,
               ci_merges_fun: fn _ -> {:ok, [%{"pr" => 5913, "merged_at_ms" => @started_ms + 30_000, "paths" => ["README.md"]}]} end
             )
  end

  test "the same failed check on approved PRs with disjoint files is base-fix evidence" do
    approved = fn number ->
      %{number: number, head: "head-#{number}", raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-#{number}", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-#{number}"}}]}}}
    end

    observations = [approved.(18), approved.(19)]
    run = %{"run_id" => nil, "name" => "test", "status" => "completed", "conclusion" => "failure", "started_at" => @started}
    history = [%{completed_at: @started_ms + 60_000, checks: [%{name: "test", conclusion: "success"}]}]

    assert {:ok, {:refresh, reason}} =
             PrRerunClassifier.classify(%{number: 18}, %{failures: [%{name: "test"}]}, [run],
               current_pr: 18,
               all_observations: observations,
               main_history_fun: fn -> history end,
               failed_checks_fun: fn _observation, _opts -> {:ok, ["test"]} end,
               changed_paths_fun: fn
                 18, _ -> {:ok, ["src/one.ex"]}
                 19, _ -> {:ok, ["src/two.ex"]}
               end
             )

    assert reason =~ "same check failed on approved PRs with disjoint changes"
    assert reason =~ "base input fix event"
  end

  test "disjoint PR failures need a later passing main check" do
    observations = [
      %{number: 18, head: "head-18", raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-18", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-18"}}]}}},
      %{number: 19, head: "head-19", raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-19", "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-19"}}]}}}
    ]

    run = %{"run_id" => nil, "name" => "test", "status" => "completed", "conclusion" => "failure", "started_at" => @started}

    opts = [
      current_pr: 18,
      all_observations: observations,
      main_history_fun: fn -> [%{completed_at: @started_ms + 60_000, checks: [%{name: "test", conclusion: "failure"}]}] end,
      failed_checks_fun: fn _observation, _opts -> {:ok, ["test"]} end,
      changed_paths_fun: fn
        18, _ -> {:ok, ["src/one.ex"]}
        19, _ -> {:ok, ["src/two.ex"]}
      end
    ]

    assert {:ok, :rework} = PrRerunClassifier.classify(%{number: 18}, %{failures: [%{name: "test"}]}, [run], opts)
  end

  test "the main-red-window rule still requires every failed PR check to be red on main" do
    run = %{
      "name" => "gate",
      "conclusion" => "failure",
      "started_at" => @started,
      "workflow_jobs" => [
        %{"name" => "audit", "conclusion" => "failure"},
        %{"name" => "test", "conclusion" => "failure"}
      ]
    }

    history = [
      %{completed_at: @started_ms - 60_000, checks: [%{name: "audit", conclusion: "failure"}, %{name: "test", conclusion: "success"}]},
      %{completed_at: @started_ms + 60_000, checks: [%{name: "audit", conclusion: "success"}, %{name: "test", conclusion: "success"}]}
    ]

    refute PrRerunClassifier.stale_merge_ref?(run, main_history_fun: fn -> history end)
  end

  test "a scripts merge does not excuse a PR-caused test failure" do
    history = [
      %{completed_at: @started_ms + 60_000, checks: [%{name: "test", conclusion: "success"}, %{name: "workflow security", conclusion: "success"}]}
    ]

    run = %{
      "run_id" => nil,
      "name" => "test",
      "status" => "completed",
      "conclusion" => "failure",
      "started_at" => @started,
      "workflow_jobs" => [%{"name" => "test", "conclusion" => "failure"}, %{"name" => "workflow security", "conclusion" => "failure"}]
    }

    assert {:ok, :rework} =
             PrRerunClassifier.classify(%{number: 18}, %{failures: [%{name: "test"}]}, [run],
               main_history_fun: fn -> history end,
               ci_merges_fun: fn _ -> {:ok, [%{"pr" => 5913, "merged_at_ms" => @started_ms + 30_000, "paths" => ["scripts/audit-hex-dependencies.py"]}]} end
             )
  end

  test "a merged dependency input is recorded for green-main base-fix detection" do
    path = Path.join(System.tmp_dir!(), "landing-ci-input-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    event = %{topic: "ticket.5921.pr.merged", pr: %{"number" => 5921, "merged_at" => "2026-10-14T11:00:00Z"}}

    assert :ok =
             PrRerun.record_merge(event,
               journal_path: path,
               base_branch: "main",
               changed_paths_fun: fn _, _ -> {:ok, ["src/mix.lock", "README.md"]} end
             )

    merged_at = @started_ms + 3_600_000
    assert {:ok, [%{"pr" => 5921, "paths" => ["src/mix.lock"], "merged_at_ms" => ^merged_at}]} = Journal.ci_merges(journal_path: path)
  end

  test "a main check that finished before the input fix does not make the PR ref stale" do
    history = [%{completed_at: @started_ms + 60_000, checks: [%{name: "audit", conclusion: "success"}]}]

    run = %{
      "run_id" => nil,
      "name" => "audit",
      "status" => "completed",
      "conclusion" => "failure",
      "started_at" => @started,
      "workflow_jobs" => [%{"name" => "audit", "conclusion" => "failure"}]
    }

    assert {:ok, :rework} =
             PrRerunClassifier.classify(%{number: 18}, %{failures: [%{name: "audit"}]}, [run],
               main_history_fun: fn -> history end,
               ci_merges_fun: fn _ -> {:ok, [%{"pr" => 5913, "merged_at_ms" => @started_ms + 120_000, "paths" => ["mix.lock"]}]} end
             )
  end
end
