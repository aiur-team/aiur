defmodule Aiur.LandingWatch.PrRerunTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch
  alias Aiur.LandingWatch.{Journal, PrRerun}

  @started "2026-10-14T10:00:00Z"
  @started_ms 1_791_972_000_000
  @flaky_log "mix test --partitions 4\n  test/aiur/flaky_test.exs:12\n1 test, 1 failure"

  test "a known flake in a test the PR does not touch reruns with its reason" do
    path = journal_path()
    assert :ok = LandingWatch.process(observation(), opts(path, known_failure_patterns: ["test/aiur/flaky_test.exs"]))
    assert_received {:rerun, 99}
    assert_received {:comment, 17, "Landing watcher reran the failed CI (ci gate) on approved head `head-sha`: known flake."}
    refute_received {:rework, _}
  end

  test "a runner failure found in the job log reruns as infrastructure" do
    assert :ok = LandingWatch.process(observation(), opts(journal_path(), job_log_fun: fn _, _ -> {:ok, "Error: The runner lost communication with the server."} end))
    assert_received {:comment, 17, body}
    assert body =~ "infrastructure failure"
  end

  test "a failure in a test the PR changed routes to rework, and the verdict is cached" do
    path = journal_path()
    changed = [changed_paths_fun: fn 17, _ -> {:ok, ["test/aiur/flaky_test.exs"]} end, known_failure_patterns: ["test/aiur/flaky_test.exs"]]

    assert :ok = LandingWatch.process(observation(), opts(path, changed))
    assert_received {:rework, [%{name: "ci gate"}]}
    refute_received {:rerun, _}

    assert :ok = LandingWatch.process(observation(), opts(path, rerun_classifier_fun: fn _, _, _, _ -> flunk("a cached PR-caused verdict skips classification") end))
    assert_received {:rework, [%{name: "ci gate"}]}
  end

  test "an unexplained failure with no flake evidence routes to rework" do
    assert :ok = LandingWatch.process(observation(), opts(journal_path()))
    assert_received {:rework, _}
    refute_received {:rerun, _}
  end

  test "a job the base workflow no longer defines reruns as superseded" do
    renamed = %{"unit" => %{"name" => "unit (${{ matrix.partition }}/4)"}, "gate" => %{"name" => "ci gate"}}
    assert :ok = LandingWatch.process(observation(), opts(journal_path(), workflow_definitions_fun: fn _, "main", _ -> {:ok, renamed} end))
    assert_received {:comment, 17, body}
    assert body =~ "superseded job name"
  end

  test "a merge ref that predates a base-branch fix reruns" do
    history = [
      %{completed_at: @started_ms - 60_000, checks: [%{name: "test (1/4)", conclusion: "failure"}]},
      %{completed_at: @started_ms + 60_000, checks: [%{name: "test (1/4)", conclusion: "success"}]}
    ]

    assert :ok = LandingWatch.process(observation(), opts(journal_path(), main_history_fun: fn -> history end))
    assert_received {:comment, 17, body}
    assert body =~ "merge ref predates a fix on the base branch"

    still_red = List.update_at(history, 1, &%{&1 | checks: [%{name: "test (1/4)", conclusion: "failure"}]})
    assert :ok = LandingWatch.process(observation(), opts(journal_path(), main_history_fun: fn -> still_red end))
    assert_received {:rework, _}
  end

  test "a merged workflow change reruns older failed runs of that workflow only" do
    path = journal_path()
    merged_after = "2026-10-14T11:00:00Z"

    record = fn number, paths ->
      PrRerun.record_merge(%{topic: "ticket.#{number}.pr.merged", pr: %{"number" => number, "merged_at" => merged_after}}, journal_path: path, changed_paths_fun: fn ^number, _ -> {:ok, paths} end)
    end

    assert :ok = record.(4600, ["README.md"])
    assert {:ok, []} = Journal.ci_merges(journal_path: path)

    assert :ok = record.(4601, [".github/workflows/website.yml"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_received {:rework, _}

    assert :ok = record.(4602, [".github/workflows/ci.yml", "README.md"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_received {:comment, 17, "Landing watcher reran the failed CI (ci gate) on approved head `head-sha`: CI change merged in #4602."}
  end

  test "a merged CI script reruns only failed jobs whose definition runs it" do
    path = journal_path()

    record = fn number, paths ->
      PrRerun.record_merge(%{topic: "system.pr.merged", pr: number, merged_at: "2026-10-14T11:00:00Z"}, journal_path: path, changed_paths_fun: fn ^number, _ -> {:ok, paths} end)
    end

    assert :ok = record.(4603, ["scripts/unrelated.sh"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_received {:rework, _}

    assert :ok = record.(4604, ["scripts/run-tests.sh"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_received {:comment, 17, body}
    assert body =~ "CI change merged in #4604"
  end

  test "the shared 3-per-15-minute cap spans merge-group requeues and PR reruns across watcher restarts" do
    path = journal_path()
    assert :ok = Journal.reserve_merge_group_requeue(@started_ms, journal_path: path)
    assert :ok = Journal.reserve_merge_group_requeue(@started_ms, journal_path: path)

    first = run_watcher(observation(), path, @started_ms)
    assert_receive {:rerun, 99}, 2_000
    stop_watcher(first)

    second_pr = %{observation() | number: 18, rest: %{"head" => %{"ref" => "aiur/18-work"}}}
    second = run_watcher(second_pr, path, @started_ms + 60_000)
    assert eventually(fn -> match?({:ok, [_]}, LandingWatch.state(second).rerun_backlog) end)
    assert {:ok, [%{"pr" => 18, "head" => "head-sha", "reason" => "known flake", "checks" => ["ci gate"]}]} = LandingWatch.state(second).rerun_backlog
    refute_received {:rerun, _}
    assert {:error, :merge_group_requeue_limit_reached} = Journal.reserve_merge_group_requeue(@started_ms + 60_000, journal_path: path)
    stop_watcher(second)

    third = run_watcher(second_pr, path, @started_ms + 15 * 60_000)
    assert_receive {:rerun, 99}, 2_000
    assert eventually(fn -> LandingWatch.state(third).rerun_backlog == {:ok, []} end)
    stop_watcher(third)
  end

  defp run_watcher(observation, path, now) do
    name = {:global, {__MODULE__, make_ref()}}
    process_opts = opts(path, known_failure_patterns: ["test/aiur/flaky_test.exs"], now_ms: now)
    watcher_opts = [name: name, interval_ms: 60_000, subscribe: false, observe_fun: fn _ -> {:ok, [observation]} end, queue_reconcile_fun: fn _, _ -> :ok end]
    {:ok, _pid} = LandingWatch.start_link(watcher_opts ++ process_opts)
    assert eventually(fn -> is_integer(LandingWatch.state(name).last_poll_at_ms) end)
    name
  end

  defp stop_watcher(name), do: GenServer.stop(name)

  defp opts(path, overrides \\ []) do
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
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => "head-sha", "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-sha"}}]}}
    }
  end

  defp failed_gate do
    %{"id" => 50, "run_id" => 99, "name" => "ci gate", "status" => "completed", "conclusion" => "failure", "started_at" => @started, "check_suite" => %{"id" => 100}}
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-pr-rerun-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
