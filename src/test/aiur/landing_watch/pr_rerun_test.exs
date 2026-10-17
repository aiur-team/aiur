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

  test "a job the base workflow no longer defines waits for a fresh merge ref, not a rerun" do
    path = journal_path()
    renamed = %{"unit" => %{"name" => "unit (${{ matrix.partition }}/4)"}, "gate" => %{"name" => "ci gate"}}
    assert :ok = LandingWatch.process(observation(), opts(path, workflow_definitions_fun: fn _, "main", _ -> {:ok, renamed} end))
    assert_refresh(path, "superseded job name")

    assert :ok = LandingWatch.process(observation(), opts(path, rerun_classifier_fun: fn _, _, _, _ -> flunk("a waiting refresh skips classification") end))
    refute_received {:rerun, _}
  end

  test "a job missing from the base workflow is the PR's own when the PR edits that workflow" do
    renamed = %{"unit" => %{"name" => "unit (${{ matrix.partition }}/4)"}}
    own = [workflow_definitions_fun: fn _, "main", _ -> {:ok, renamed} end, changed_paths_fun: fn 17, _ -> {:ok, [".github/workflows/ci.yml"]} end]
    assert :ok = LandingWatch.process(observation(), opts(journal_path(), own))
    assert_received {:rework, _}
    refute_received {:rerun, _}
  end

  test "a merge into a stacked branch is not recorded as a base CI change" do
    path = journal_path()
    event = %{topic: "ticket.4605.pr.merged", pr: %{"number" => 4605, "base" => %{"ref" => "aiur/4600-parent"}}}
    assert :ok = PrRerun.record_merge(event, journal_path: path, base_branch: "main", changed_paths_fun: fn _, _ -> flunk("a stacked merge needs no path read") end)
    assert {:ok, []} = Journal.ci_merges(journal_path: path)
  end

  test "a merge ref that predates a base-branch fix waits for a fresh merge ref" do
    path = journal_path()

    history = [
      %{completed_at: @started_ms - 60_000, checks: [%{name: "test (1/4)", conclusion: "failure"}]},
      %{completed_at: @started_ms + 60_000, checks: [%{name: "test (1/4)", conclusion: "success"}]}
    ]

    assert :ok = LandingWatch.process(observation(), opts(path, main_history_fun: fn -> history end))
    assert_refresh(path, "merge ref predates a fix on the base branch")

    still_red = List.update_at(history, 1, &%{&1 | checks: [%{name: "test (1/4)", conclusion: "failure"}]})
    assert :ok = LandingWatch.process(observation(), opts(journal_path(), main_history_fun: fn -> still_red end))
    assert_received {:rework, _}
  end

  test "a merged workflow change sends older failed runs of that workflow only to a fresh merge ref" do
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
    assert_refresh(path, "CI change merged in #4602")
  end

  test "a merged CI script sends only failed jobs whose definition runs it to a fresh merge ref" do
    path = journal_path()

    record = fn number, paths ->
      PrRerun.record_merge(%{topic: "system.pr.merged", pr: number, merged_at: "2026-10-14T11:00:00Z"}, journal_path: path, changed_paths_fun: fn ^number, _ -> {:ok, paths} end)
    end

    assert :ok = record.(4603, ["scripts/unrelated.sh"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_received {:rework, _}

    assert :ok = record.(4604, ["scripts/run-tests.sh"])
    assert :ok = LandingWatch.process(observation(), opts(path))
    assert_refresh(path, "CI change merged in #4604")
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

  test "an exhausted or backed-off head is not classified again" do
    path = journal_path()
    skip = [rerun_classifier_fun: fn _, _, _, _ -> flunk("a head the budget refuses skips classification") end]
    now = @started_ms + 3_600_000

    assert :ok = Journal.reserve_rerun(17, "head-sha", now - 1_000, journal_path: path)
    assert :ok = LandingWatch.process(observation(), opts(path, skip))
    refute_received {:rerun, _}

    exhausted = journal_path()
    assert :ok = Journal.reserve_rerun(17, "head-sha", now - 2 * 86_400_000, journal_path: exhausted)
    assert :ok = Journal.reserve_rerun(17, "head-sha", now - 86_400_000, journal_path: exhausted)
    parent = self()
    alert = [alert_emitter: fn topic, _ -> send(parent, {:alert, topic}) && :ok end]

    assert :ok = LandingWatch.process(observation(), opts(exhausted, skip ++ alert))
    assert_received {:alert, "ticket.17.pr.ci_recovery.rerun_limit"}
    assert :ok = LandingWatch.process(observation(), opts(exhausted, skip ++ alert))
    refute_received {:alert, _}
  end

  test "reruns and classifier reads are metered under the landing watcher's caller" do
    parent = self()

    metered = [
      actions_run_fun: fn 99, opts -> send(parent, {:caller, :read, opts[:caller]}) && {:ok, %{"path" => ".github/workflows/ci.yml"}} end,
      rerun_fun: fn 99, opts -> send(parent, {:caller, :rerun, opts[:caller]}) && {:ok, %{}} end,
      known_failure_patterns: ["test/aiur/flaky_test.exs"]
    ]

    assert :ok = LandingWatch.process(observation(), opts(journal_path(), metered))
    assert_received {:caller, :read, "landing_watch_pr_rerun"}
    assert_received {:caller, :rerun, "landing_watch_pr_rerun"}
  end

  test "a mix of infrastructure and known-flake jobs names both causes" do
    second = %{"id" => 9, "name" => "test (2/4)", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => @started, "completed_at" => "2026-10-14T10:05:00Z"}

    logs = fn
      %{"id" => 7}, _ -> {:ok, @flaky_log}
      %{"id" => 9}, _ -> {:ok, "Error: The runner lost communication with the server."}
    end

    mixed = [jobs_fun: fn 99, _ -> {:ok, [second | jobs()]} end, job_log_fun: logs, known_failure_patterns: ["test/aiur/flaky_test.exs"]]

    assert :ok = LandingWatch.process(observation(), opts(journal_path(), mixed))
    assert_received {:comment, 17, body}
    assert body =~ ": infrastructure failure; known flake."
  end

  test "one cause a rerun cannot fix sends the whole head to a fresh merge ref" do
    path = journal_path()
    lint_run = %{failed_gate() | "id" => 51, "run_id" => 98, "name" => "lint"}
    lint_job = %{"id" => 11, "name" => "lint", "conclusion" => "failure", "steps" => [%{"conclusion" => "failure"}], "started_at" => @started, "completed_at" => "2026-10-14T10:05:00Z"}

    mixed = [
      required_checks_fun: fn _ -> {:ok, [%{name: "lint", app_id: nil}, %{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [lint_run, failed_gate()], commit_status: %{"state" => "success", "statuses" => []}}} end,
      jobs_fun: fn
        99, _ -> {:ok, jobs()}
        98, _ -> {:ok, [lint_job]}
      end,
      actions_run_fun: fn _, _ -> {:ok, %{"path" => ".github/workflows/ci.yml"}} end,
      known_failure_patterns: ["test/aiur/flaky_test.exs"]
    ]

    assert :ok = LandingWatch.process(observation(), opts(path, mixed))
    refute_received {:rerun, _}
    refute_received {:comment, _, _}
    assert {:ok, [%{"pr" => 17, "action" => "refresh", "reason" => "superseded job name", "checks" => ["lint", "ci gate"]}]} = Journal.rerun_backlog(journal_path: path)
  end

  defp assert_refresh(path, reason) do
    refute_received {:rerun, _}
    refute_received {:comment, _, _}
    assert {:ok, [%{"pr" => 17, "action" => "refresh", "reason" => ^reason, "checks" => ["ci gate"]}]} = Journal.rerun_backlog(journal_path: path)
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
