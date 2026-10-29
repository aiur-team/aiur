defmodule Aiur.LandingWatch.MainRecoveryRerunTest do
  use Aiur.TestSupport

  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.Journal

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    :ok
  end

  @started "2026-10-14T10:00:00Z"
  @started_ms 1_791_972_000_000
  @flaky_log "mix test --partitions 4\n  test/aiur/flaky_test.exs:12\n1 test, 1 failure"

  test "deferred recovery keeps only run IDs that started during the red interval" do
    path = journal_path()
    armed = %{observation() | auto_merge_request: %{"enabledAt" => "2026-10-14T09:00:00Z"}}
    in_window = failed_gate() |> Map.put("started_at", @started)
    outside = failed_gate() |> Map.put("run_id", 100) |> Map.put("id", 51) |> Map.put("started_at", "2026-10-14T09:58:00Z")
    for _ <- 1..4, do: assert(:ok = Journal.reserve_merge_group_requeue(@started_ms + 3_600_000, journal_path: path))
    checks = [in_window, outside]

    assert :ok =
             LandingWatch.process(
               armed,
               opts(path,
                 main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000},
                 ci_status_fun: fn _, _ -> {:ok, %{check_runs: checks, commit_status: %{"state" => "success", "statuses" => []}}} end,
                 jobs_fun: fn id, _ -> {:ok, jobs_for_run(id)} end
               )
             )

    assert {:ok, [%{"run_ids" => [99]}]} = Journal.rerun_backlog(journal_path: path)

    later =
      opts(path,
        ci_status_fun: fn _, _ -> {:ok, %{check_runs: checks, commit_status: %{"state" => "success", "statuses" => []}}} end,
        jobs_fun: fn id, _ -> {:ok, jobs_for_run(id)} end,
        now_ms: @started_ms + 3_600_000 + 15 * 60_000
      )

    assert :ok = LandingWatch.process(armed, later)
    assert_received {:rerun, 99}
    refute_received {:rerun, 100}
    assert {:ok, []} = Journal.rerun_backlog(journal_path: path)
  end

  test "recovery reruns consume one shared cap slot per workflow run" do
    path = journal_path()
    armed = %{observation() | auto_merge_request: %{"enabledAt" => "2026-10-14T09:00:00Z"}}
    runs = for id <- 99..101, do: failed_gate() |> Map.put("run_id", id) |> Map.put("id", id - 49) |> Map.put("started_at", @started)
    for _ <- 1..3, do: assert(:ok = Journal.reserve_merge_group_requeue(@started_ms + 3_600_000, journal_path: path))

    assert :ok =
             LandingWatch.process(
               armed,
               opts(path,
                 main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000},
                 ci_status_fun: fn _, _ -> {:ok, %{check_runs: runs, commit_status: %{"state" => "success", "statuses" => []}}} end,
                 jobs_fun: fn id, _ -> {:ok, jobs_for_run(id)} end
               )
             )

    assert_received {:rerun, 99}
    refute_received {:rerun, 100}
    assert {:ok, [%{"run_ids" => [100, 101]}]} = Journal.rerun_backlog(journal_path: path)
    assert {:ok, state} = Journal.state(journal_path: path)
    assert length(state["merge_group_requeues"]) == 4
  end

  test "recovery backlog drains across cap windows without spending another per-head attempt" do
    path = journal_path()
    armed = %{observation() | auto_merge_request: %{"enabledAt" => "2026-10-14T09:00:00Z"}}
    runs = for id <- 99..106, do: failed_gate() |> Map.put("run_id", id) |> Map.put("id", id - 49) |> Map.put("started_at", @started)
    shared = [ci_status_fun: fn _, _ -> {:ok, %{check_runs: runs, commit_status: %{"state" => "success", "statuses" => []}}} end, jobs_fun: fn id, _ -> {:ok, jobs_for_run(id)} end]

    assert :ok = LandingWatch.process(armed, opts(path, shared ++ [main_ci_recovery_window: {@started_ms - 60_000, @started_ms + 60_000}]))
    assert {:ok, [%{"run_ids" => [103, 104, 105, 106], "per_head_reserved" => true}]} = Journal.rerun_backlog(journal_path: path)
    assert_received {:rerun, 99}
    assert_received {:rerun, 100}
    assert_received {:rerun, 101}
    assert_received {:rerun, 102}

    later = shared ++ [now_ms: @started_ms + 3_600_000 + 15 * 60_000]
    assert :ok = LandingWatch.process(armed, opts(path, later))
    assert_received {:rerun, 103}
    assert_received {:rerun, 104}
    assert_received {:rerun, 105}
    assert_received {:rerun, 106}
    assert {:ok, []} = Journal.rerun_backlog(journal_path: path)
  end

  defp opts(path, overrides) do
    parent = self()

    Keyword.merge(
      [
        approved_fun: fn _, _ -> {:ok, true} end,
        required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
        ci_status_fun: fn _, _ -> {:ok, %{check_runs: [failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
        jobs_fun: fn 99, _ -> {:ok, jobs()} end,
        actions_run_fun: fn 99, _ -> {:ok, %{"path" => ".github/workflows/ci.yml"}} end,
        workflow_definitions_fun: fn ".github/workflows/ci.yml", "main", _ -> {:ok, definitions()} end,
        main_history_fun: fn -> [] end,
        base_branch: "main",
        changed_paths_fun: fn _, _ -> {:ok, ["src/lib/aiur/feature.ex"]} end,
        known_failure_patterns: [],
        recent_main_failure_paths: [],
        job_log_fun: fn _, _ -> {:ok, @flaky_log} end,
        rerun_fun: fn id, _ ->
          send(parent, {:rerun, id})
          {:ok, %{}}
        end,
        base_changes_fun: fn "head-sha", "main", _ -> {:ok, ["README.md"]} end,
        update_branch_fun: fn number, head, _ ->
          send(parent, {:update_branch, number, head})
          {:ok, %{}}
        end,
        observe_refresh_fun: fn _, _ -> {:ok, %{"headRefOid" => "refreshed-sha"}} end,
        approval_carry_classifier: fn _, _, _, _ -> :identical end,
        comment_fun: fn number, body, _ ->
          send(parent, {:comment, number, body})
          {:ok, %{}}
        end,
        rework_fun: fn _, failures, _ ->
          send(parent, {:rework, failures})
          :ok
        end,
        journal_path: path,
        now_ms: @started_ms + 3_600_000
      ],
      overrides
    )
  end

  defp jobs do
    [
      %{"id" => 7, "name" => "test (1/4)", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => @started, "completed_at" => "2026-10-14T10:05:00Z"},
      %{"id" => 8, "name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => "2026-10-14T10:06:00Z", "completed_at" => "2026-10-14T10:06:05Z"}
    ]
  end

  defp definitions do
    %{"test" => %{"name" => "test (${{ matrix.partition }}/4)", "steps" => [%{"run" => "bash scripts/run-tests.sh"}]}, "gate" => %{"name" => "ci gate"}}
  end

  defp observation do
    %{
      number: 17,
      node_id: "PR_node",
      head: "head-sha",
      draft?: false,
      review_decision: "APPROVED",
      reviews: [%{"commit" => %{"oid" => "head-sha"}}],
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp failed_gate do
    %{"id" => 50, "run_id" => 99, "name" => "ci gate", "status" => "completed", "conclusion" => "failure", "started_at" => @started, "check_suite" => %{"id" => 100}}
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-main-recovery-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end

  defp jobs_for_run(id) do
    [%{"name" => "ci gate", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => @started, "completed_at" => "2026-10-14T10:06:05Z", "run_id" => id}]
  end
end
