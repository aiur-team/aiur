defmodule Aiur.LandingWatch.MergeGroupFailureRepeatTest do
  use ExUnit.Case, async: false
  # Each test gets a fresh ExUnit tmp_dir: a /tmp path keyed only by unique_integer collides across VMs and with stale files.
  @moduletag :tmp_dir
  import ExUnit.CaptureLog

  alias Aiur.IssueLog.Writers
  alias Aiur.LandingWatch.{Journal, MergeGroupFailureProcessor, MergeGroupRequeue}
  alias Aiur.TrackerIdentity

  test "a repeated merge-group failure is published to the linked ticket journal", %{tmp_dir: tmp_dir} do
    original_log_file = Application.get_env(:aiur, :log_file)
    original_runtime_state_dir = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "log/aiur.log"))
    Application.put_env(:aiur, :runtime_state_dir, Path.join(tmp_dir, "state"))

    on_exit(fn -> restore_test_environment(original_log_file, original_runtime_state_dir) end)

    unique = System.unique_integer([:positive])
    repository = {"owner", "repo-#{unique}"}
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I#{unique}", "number" => "17"}, repository, repository)
    :ok = Aiur.IssueLog.attach(identity)
    writer = writer_pid(identity)
    on_exit(fn -> Aiur.TestSupport.safe_stop(writer) end)
    path = journal_path(tmp_dir)
    parent = self()
    identity_fun = fn "17" -> identity end

    assert :ok = process_failure(701, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent, ticket_identity_fun: identity_fun)
    assert :ok = process_failure(702, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent, ticket_identity_fun: identity_fun)
    _ = :sys.get_state(writer)

    assert {:ok,
            %{
              events: [
                %{topic: "ticket.17.ci.merge_group.requeued", summary: first_requeue},
                %{topic: "ticket.17.ci.merge_group.failed", summary: summary, ci_checks: [%{name: check}]}
              ]
            }} =
             Aiur.IssueLog.event_history_page(identity, after_id: 0)

    assert first_requeue =~ "Merge-group run #701 requeued PR #17"
    assert summary =~ "Merge-group run 702 failed"
    assert check =~ "reports parity"

    pr = Map.merge(observation(), %{mergeable: "MERGEABLE", merge_state_status: "CLEAN"})

    requeue_options = [
      journal_path: Path.join(tmp_dir, "requeue.json"),
      ticket_identity_fun: identity_fun,
      ticket_state_fun: fn "17", _ -> {:ok, %{state: "ci-wait", paused?: false, held?: false}} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      approved_fun: fn _, _ -> {:ok, true} end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      enqueue_fun: fn _, _, _ -> {:ok, "entry-17"} end,
      comment_fun: fn _, _, _ -> :ok end
    ]

    assert :ok = MergeGroupRequeue.requeue_group_prs([17], [pr], %{"id" => 703}, "runner failure", requeue_options)
    _ = :sys.get_state(writer)

    assert {:ok,
            %{
              events: [
                %{topic: "ticket.17.ci.merge_group.requeued"},
                %{topic: "ticket.17.ci.merge_group.failed"},
                %{topic: "ticket.17.ci.merge_group.requeued", summary: requeue_summary}
              ]
            }} =
             Aiur.IssueLog.event_history_page(identity, after_id: 0)

    assert requeue_summary =~ "Merge-group run #703 requeued PR #17: runner failure"
  end

  test "the first PR-caused merge-group failure reaches the linked ticket journal", %{tmp_dir: tmp_dir} do
    original_log_file = Application.get_env(:aiur, :log_file)
    original_runtime_state_dir = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :log_file, Path.join(tmp_dir, "log/aiur.log"))
    Application.put_env(:aiur, :runtime_state_dir, Path.join(tmp_dir, "state"))

    on_exit(fn -> restore_test_environment(original_log_file, original_runtime_state_dir) end)

    unique = System.unique_integer([:positive])
    repository = {"owner", "repo-#{unique}"}
    {:ok, identity} = TrackerIdentity.from_github(%{"node_id" => "I#{unique}", "number" => "17"}, repository, repository)
    :ok = Aiur.IssueLog.attach(identity)
    writer = writer_pid(identity)
    on_exit(fn -> Aiur.TestSupport.safe_stop(writer) end)

    assert :ok =
             process_failure(
               704,
               [{"reports parity", "src/aiur/parity.ex"}],
               journal_path(tmp_dir),
               self(),
               changed_paths_by_pr: %{17 => ["src/aiur/parity.ex"]},
               ticket_identity_fun: fn "17" -> identity end
             )

    _ = :sys.get_state(writer)
    assert {:ok, %{events: [%{topic: topic, summary: summary, ci_checks: [%{name: check}]}]}} = Aiur.IssueLog.event_history_page(identity, after_id: 0)
    assert topic == "ticket.17.ci.merge_group.failed"
    assert summary =~ "Merge-group run 704 failed"
    assert check == "parity"
  end

  test "a second browser spec failure routes to rework and holds the head without enqueueing", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)
    identity = "BrowserSpec :: src/browser/tests/build-home-tools-parity.browser.spec.mjs"

    assert :ok = process_browser_failure(501, path, parent)
    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert :ok = process_browser_failure(502, path, parent)
    assert_received {:rework, 17, _failures}
    refute_received {:enqueue, 17}
    assert {:ok, true} = Journal.merge_group_head_held?(17, "head-17", journal_path: path)
    assert {:ok, 1} = Journal.merge_group_failure_attempts(17, "head-17", identity, journal_path: path)
  end

  test "a second failure of the same spec routes the PR to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok = process_failure(101, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert :ok = process_failure(102, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:rework, 17}
    refute_received {:enqueue, 17}

    assert {:ok, 1} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )
  end

  test "a different failing spec gets its own re-enqueue", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok = process_failure(201, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}
    assert :ok = process_failure(202, [{"reports other", "test/aiur/other_test.exs"}], path, parent)

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert {:ok, 1} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )
  end

  test "different tests in one file get independent repeat counters", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok = process_failure(221, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}

    assert :ok = process_failure(222, [{"reports another parity", "test/aiur/parity_test.exs"}], path, parent)

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}
  end

  test "a repeated spec among multiple failures routes the PR to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok = process_failure(251, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent)
    assert_received {:enqueue, 17}

    assert :ok =
             process_failure(
               252,
               [
                 {"reports parity", "test/aiur/parity_test.exs"},
                 {"reports other", "test/aiur/other_test.exs"}
               ],
               path,
               parent
             )

    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
  end

  test "a prior multi-spec failure is detected when only one spec repeats", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok =
             process_failure(
               261,
               [
                 {"reports parity", "test/aiur/parity_test.exs"},
                 {"reports other", "test/aiur/other_test.exs"}
               ],
               path,
               parent
             )

    assert_received {:enqueue, 17}
    assert :ok = process_failure(262, [{"reports other", "test/aiur/other_test.exs"}], path, parent)
    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
  end

  test "a repeated known non-PR failure with unknown blame routes to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)
    tests = [{"reports parity", "test/aiur/parity_test.exs"}]

    extra_opts = [
      jobs_fun: fn run_id, _ ->
        {:ok,
         [
           %{"id" => run_id + 1, "name" => "parity", "conclusion" => "failure"},
           %{"id" => run_id + 2, "name" => "runner diagnostics", "conclusion" => "failure"}
         ]}
      end,
      job_log_fun: fn
        %{"name" => "parity"}, _ -> {:ok, failure_log(tests)}
        %{"name" => "runner diagnostics"}, _ -> {:ok, "test failed before a test case was reported"}
      end
    ]

    log = capture_log(fn -> assert :ok = process_failure(401, tests, path, parent, extra_opts) end)
    assert log =~ "merge-group blame evidence incomplete; using legacy routing"
    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert :ok = process_failure(402, tests, path, parent, extra_opts)
    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
  end

  test "a first unresolved PR-caused failure holds the head while routing to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok =
             process_failure(281, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent, recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end)

    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
    assert {:ok, true} = Journal.merge_group_head_held?(17, "head-17", journal_path: path)
  end

  test "infrastructure and inherited failures requeue without consuming repeat attempts", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)
    tests = [{"reports parity", "test/aiur/parity_test.exs"}]

    for {run_id, log, identity} <- [
          {601, "runner lost before job setup", "infrastructure failure"},
          {602, "failure in an earlier merge group", "inherited merge-group failure"}
        ] do
      assert :ok =
               process_failure(run_id, tests, path, parent, job_log_fun: fn _, _ -> {:ok, log} end)

      assert_received {:enqueue, 17}
      assert {:ok, 0} = Journal.merge_group_failure_attempts(17, "head-17", identity, journal_path: path)
    end
  end

  test "a first quarantined failure re-enqueues and a repeated one routes to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    assert :ok =
             process_failure(301, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent,
               quarantined_run_ids: [301, 302],
               recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end
             )

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}

    assert {:ok, 1} =
             Journal.merge_group_failure_attempts(
               17,
               "head-17",
               "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs",
               journal_path: path
             )

    assert :ok =
             process_failure(302, [{"reports parity", "test/aiur/parity_test.exs"}], path, parent,
               quarantined_run_ids: [301, 302],
               recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end
             )

    assert_received {:rework, 17}
    refute_received {:enqueue, 17}
    assert {:ok, true} = Journal.merge_group_head_held?(17, "head-17", journal_path: path)
  end

  test "failure attempt journal is capped", %{tmp_dir: tmp_dir} do
    path = journal_path(tmp_dir)
    failures = for n <- 1..1_005, do: {n, "head-#{n}", ["spec-#{n}"]}

    assert {:ok, _counts} = Journal.record_merge_group_failure_attempts(failures, journal_path: path)
    assert {:ok, state} = Journal.state(journal_path: path)
    assert map_size(state["merge_group_failure_attempts"]) == 1_000
  end

  test "per-spec repeat counters are pruned to each PR's current head", %{tmp_dir: tmp_dir} do
    path = journal_path(tmp_dir)
    opts = [journal_path: path]
    identity = "test reports parity (Aiur.ParityTest) :: src/test/aiur/parity_test.exs"
    other_identity = "test reports other (Aiur.OtherTest) :: src/test/aiur/other_test.exs"
    old_identity = "test reports previous parity (Aiur.ParityTest) :: src/test/aiur/previous_parity_test.exs"

    assert {:ok, _} =
             Journal.record_merge_group_failure_attempts(
               [
                 {17, "head-17", [identity]},
                 {17, "old-head-17", [old_identity]},
                 {18, "head-18", [other_identity]}
               ],
               opts
             )

    assert :ok = Journal.retain_current_heads([%{number: 17, head: "head-17"}], opts)
    assert {:ok, 1} = Journal.merge_group_failure_attempts(17, "head-17", identity, opts)
    assert {:ok, 0} = Journal.merge_group_failure_attempts(17, "old-head-17", old_identity, opts)
    assert {:ok, 0} = Journal.merge_group_failure_attempts(18, "head-18", other_identity, opts)
  end

  test "a cancelled merge-group run is ignored", %{tmp_dir: tmp_dir} do
    path = journal_path(tmp_dir)
    run = failed_run(401, "cancelled")

    assert :ok =
             MergeGroupFailureProcessor.process_completed(
               [run],
               [observation()],
               "main",
               journal_path: path,
               jobs_fun: fn _, _ -> flunk("cancelled runs are not classified") end
             )

    refute File.exists?(path)
  end

  test "the cancelled incident job shape is requeued without sending its PR to rework", %{tmp_dir: tmp_dir} do
    parent = self()
    path = journal_path(tmp_dir)

    jobs =
      [%{"id" => 1, "name" => "changes", "conclusion" => "success"}, %{"id" => 2, "name" => "soak", "conclusion" => "skipped"}, %{"id" => 3, "name" => "quarantined tests", "conclusion" => "skipped"}] ++
        for(index <- 1..27, do: %{"id" => 3 + index, "name" => "test (#{index}/27)", "conclusion" => "cancelled"}) ++
        [%{"id" => 31, "name" => "ci gate", "conclusion" => "failure"}]

    assert :ok =
             process_failure(40_053_094_689, [], path, parent, jobs_fun: fn _, _ -> {:ok, jobs} end)

    assert_received {:enqueue, 17}
    refute_received {:rework, 17}
  end

  defp process_failure(run_id, tests, journal, parent, extra_opts \\ []) do
    run = failed_run(run_id, "failure")
    log = failure_log(tests)

    opts = [
      journal_path: journal,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, Enum.map(tests, fn {_name, path} -> "src/" <> path end)} end,
      known_failure_patterns: [],
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      changed_paths_by_pr: %{17 => []},
      ticket_state_fun: fn _, _ -> {:ok, %{state: "human-review", paused?: false, held?: false}} end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => run_id + 1, "name" => "parity", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ -> {:ok, log} end,
      repo_fun: fn -> {:ok, {"owner", "repo"}} end,
      enqueue_fun: fn node, _head, _ ->
        send(parent, {:enqueue, 17})
        {:ok, "entry-#{node}"}
      end,
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      rework_fun: fn pr, _failures, _ ->
        send(parent, {:rework, pr.number})
        :ok
      end
    ]

    MergeGroupFailureProcessor.process_completed([run], [observation()], "main", Keyword.merge(opts, extra_opts))
  end

  defp process_browser_failure(run_id, journal, parent) do
    run = failed_run(run_id, "failure")
    log = "new-failure :: BrowserSpec :: src/browser/tests/build-home-tools-parity.browser.spec.mjs"

    opts = [
      journal_path: journal,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, ["src/browser/tests/build-home-tools-parity.browser.spec.mjs"]} end,
      known_failure_patterns: [],
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      changed_paths_by_pr: %{17 => []},
      ticket_state_fun: fn _, _ -> {:ok, %{state: "human-review", paused?: false, held?: false}} end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => run_id + 1, "name" => "browser smoke (3/9)", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ -> {:ok, log} end,
      repo_fun: fn -> {:ok, {"owner", "repo"}} end,
      enqueue_fun: fn node, _, _ ->
        send(parent, {:enqueue, 17})
        {:ok, "entry-#{node}"}
      end,
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      rework_fun: fn pr, failures, _ ->
        send(parent, {:rework, pr.number, failures})
        :ok
      end
    ]

    MergeGroupFailureProcessor.process_completed([run], [observation()], "main", opts)
  end

  defp failure_log(tests) do
    tests
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {{name, path}, index} ->
      "  #{index}) test #{name} (Aiur.ParityTest)\n     #{path}:42"
    end)
  end

  defp failed_run(id, conclusion) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => conclusion,
      "head_branch" => "gh-readonly-queue/main/pr-17-a"
    }
  end

  defp observation do
    %{
      number: 17,
      base: "main",
      head: "head-17",
      node_id: "PR_17",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}}
    }
  end

  defp writer_pid(identity) do
    [{pid, _}] = Registry.lookup(Aiur.IssueLog.Registry, Writers.writer_key(identity))
    pid
  end

  defp journal_path(tmp_dir), do: Path.join(tmp_dir, "journal.json")

  defp restore_test_environment(log_file, state_dir) do
    Enum.each([{:log_file, log_file}, {:runtime_state_dir, state_dir}], fn
      {key, nil} -> Application.delete_env(:aiur, key)
      {key, value} -> Application.put_env(:aiur, key, value)
    end)
  end
end
