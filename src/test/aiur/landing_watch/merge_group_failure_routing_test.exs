defmodule Aiur.LandingWatch.MergeGroupFailureRoutingTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "a failed test in the last day's base-branch runs requeues an untouched failure" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-main-failure-#{System.unique_integer([:positive])}.json"
      )

    failed = group_run(406, "failure", "pr-17-a")
    main = %{"id" => 405, "event" => "push", "status" => "completed", "conclusion" => "failure"}

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/pr-17-a"}]}}

      %{method: :get, url: url} ->
        runs =
          cond do
            String.contains?(url, "branch=main") ->
              [main]

            String.contains?(url, "event=merge_group") and String.contains?(url, "status=completed") ->
              [failed]

            true ->
              []
          end

        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    pr = %{
      number: 17,
      base: "main",
      head: "current",
      node_id: "PR_17",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}}
    }

    options = [
      base_branch: "main",
      token: "test-gh-token",
      now_ms: 1_800_000_000_000,
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, [pr]} end,
      jobs_fun: fn id, _ ->
        {:ok, [%{"id" => id, "name" => "test", "conclusion" => "failure"}]}
      end,
      job_log_fun: fn _, _ ->
        {:ok, "  1) test base failure (Aiur.ExampleTest)\n     test/aiur/example_test.exs:12"}
      end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/lib/changed.ex"]} end,
      known_failure_patterns: [],
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      enqueue_fun: fn node, head, _ ->
        send(parent, {:enqueue, node, head})
        {:ok, "entry-17"}
      end
    ]

    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:enqueue, "PR_17", "current"}
    File.rm(journal)
  end

  test "a test failure in a PR-touched file routes to rework with its run URL" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-pr-failure-#{System.unique_integer([:positive])}.json"
      )

    run = group_run(305, "failure", "pr-17-a")

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/pr-17-a"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [run], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    pr = %{
      number: 17,
      base: "main",
      head: "current",
      node_id: "PR_17",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}}
    }

    options = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, [pr]} end,
      job_log_fun: fn _, _ -> {:ok, "  1) test failed (Aiur.ChangedTest)\n     test/aiur/changed_test.exs:12"} end,
      jobs_fun: fn _, _ ->
        {:ok, [%{"id" => 901, "name" => "test", "conclusion" => "failure"}]}
      end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/test/aiur/changed_test.exs"]} end,
      known_failure_patterns: [],
      repo_fun: fn -> {:ok, {"aiur-team", "aiur"}} end,
      rework_fun: fn observation, failures, opts ->
        send(parent, {:rework, observation.number, failures, Keyword.fetch!(opts, :run_url)})
        :ok
      end,
      enqueue_fun: fn _, _, _ ->
        send(parent, :unexpected_enqueue)
        {:ok, "entry"}
      end
    ]

    assert :ok = MergeGroups.cancel_stale([], options)

    assert_received {:rework, 17, [%{name: "test", excerpt: excerpt}], "https://github.com/aiur-team/aiur/actions/runs/305"}

    assert String.contains?(excerpt, "changed_test.exs")
    refute_received :unexpected_enqueue
    File.rm(journal)
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
end
