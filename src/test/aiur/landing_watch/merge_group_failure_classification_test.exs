defmodule Aiur.LandingWatch.MergeGroupFailureClassificationTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeFailureClassifier

  test "recorded coverage shard cascade and browser cancellation classify as infrastructure" do
    coverage = fixture("run-38746066535-coverage.log")
    browser = fixture("run-38742645458-browser.log")

    assert {:ok, {:infra, _}} =
             MergeFailureClassifier.classify(
               group_run(301, "failure", "pr-17-a"),
               [%{"name" => "coverage (4/4)", "conclusion" => "failure"}],
               [],
               job_log_fun: fn _, _ -> {:ok, coverage} end
             )

    timed_out_browser = %{
      "name" => "browser smoke (3/3)",
      "conclusion" => "cancelled",
      "started_at" => "2026-10-15T13:32:38Z",
      "completed_at" => "2026-10-15T13:47:38Z"
    }

    assert {:ok, {:infra, _}} =
             MergeFailureClassifier.classify(
               group_run(302, "failure", "pr-17-a"),
               [timed_out_browser],
               [],
               job_log_fun: fn _, _ -> {:ok, browser} end,
               timeout_minutes_by_job: %{"browser smoke (3/3)" => 15}
             )

    unverified_cancellation = fixture("run-38729249620-browser.log")

    assert {:ok, {:pr_caused, _}} =
             MergeFailureClassifier.classify(
               group_run(305, "failure", "pr-17-a"),
               [%{"name" => "browser smoke", "conclusion" => "cancelled"}],
               [],
               job_log_fun: fn _, _ -> {:ok, unverified_cancellation} end
             )
  end

  test "only a cancellation that reaches its timeout is infrastructure" do
    log = fixture("run-38742645458-browser.log")
    run = group_run(407, "failure", "pr-17-a")

    assert {:ok, {:pr_caused, _}} =
             MergeFailureClassifier.classify(
               run,
               [%{"name" => "browser", "conclusion" => "cancelled"}],
               [],
               job_log_fun: fn _, _ -> {:ok, log} end
             )

    unrelated_timeout_log = "test output includes the words timed out in an assertion message"

    short_cancel = %{
      "name" => "browser",
      "conclusion" => "cancelled",
      "started_at" => "2026-10-15T13:30:00Z",
      "completed_at" => "2026-10-15T13:40:00Z"
    }

    assert {:ok, {:pr_caused, _}} =
             MergeFailureClassifier.classify(run, [short_cancel], [],
               job_log_fun: fn _, _ -> {:ok, unrelated_timeout_log} end,
               timeout_minutes_by_job: %{"browser" => 15}
             )

    test_failure = %{
      "name" => "test",
      "conclusion" => "failure",
      "started_at" => "2026-10-15T13:30:00Z",
      "completed_at" => "2026-10-15T13:33:00Z"
    }

    assert {:ok, {:pr_caused, _}} =
             MergeFailureClassifier.classify(run, [test_failure], [], job_log_fun: fn _, _ -> {:ok, unrelated_timeout_log} end)

    timed_out = %{
      "name" => "browser",
      "conclusion" => "cancelled",
      "started_at" => "2026-10-15T13:30:00Z",
      "completed_at" => "2026-10-15T13:45:00Z"
    }

    assert {:ok, {:infra, _}} =
             MergeFailureClassifier.classify(run, [timed_out], [],
               job_log_fun: fn _, _ -> {:ok, log} end,
               timeout_minutes_by_job: %{"browser" => 15}
             )
  end

  test "recorded inherited ci gate failure is classified separately from PR test failures" do
    log = fixture("run-38742654941-inherited.log")

    jobs = [
      %{
        "name" => "ci gate",
        "conclusion" => "failure",
        "needs_json" => ~s({"workflow-security":{"result":"failure"},"lint":{"result":"success"}})
      }
    ]

    assert {:ok, {:inherited, _}} =
             MergeFailureClassifier.classify(group_run(303, "failure", "pr-17-a"), jobs, [], job_log_fun: fn _, _ -> {:ok, log} end)
  end

  test "known failure in untouched file is non-PR while a touched-file failure stays PR-caused" do
    log = "mix test src/test/aiur/example_test.exs:12 test issue signature failed"
    run = group_run(304, "failure", "pr-17-a")
    jobs = [%{"name" => "test", "conclusion" => "failure"}]

    opts = [
      job_log_fun: fn _, _ -> {:ok, log} end,
      known_failure_patterns: ["example_test.exs"],
      changed_paths_fun: fn _, _ -> {:ok, ["src/lib/changed.ex"]} end,
      changed_paths_by_pr: %{17 => ["src/lib/changed.ex"]}
    ]

    assert {:ok, {:known_non_pr, _}} = MergeFailureClassifier.classify(run, jobs, [], opts)

    touched_opts =
      Keyword.put(opts, :changed_paths_by_pr, %{17 => ["src/test/aiur/example_test.exs"]})

    assert {:ok, {:pr_caused, _}} = MergeFailureClassifier.classify(run, jobs, [], touched_opts)

    main_failure_opts =
      opts
      |> Keyword.put(:known_failure_patterns, [])
      |> Keyword.put(:failed_on_main_fun, fn _, _ -> true end)

    assert {:ok, {:known_non_pr, _}} =
             MergeFailureClassifier.classify(run, jobs, [], main_failure_opts)
  end

  defp group_run(id, conclusion, prs) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => conclusion,
      "head_branch" => "gh-readonly-queue/main/#{prs}"
    }
  end

  defp fixture(name),
    do: Path.join([__DIR__, "../../fixtures/landing_watch", name]) |> Path.expand() |> File.read!()
end
