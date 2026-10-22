defmodule Aiur.LandingWatch.MergeGroupFailureRequeueTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "a recorded known non-PR failure re-enqueues the dropped approved PR once" do
    parent = self()

    journal = journal_path("flake")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    failed = group_run(201, "failure", "pr-17-a")
    passed = group_run(202, "success", "pr-17-b")

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/pr-17-a"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [failed, passed], else: []
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
      job_log_fun: fn _, _ ->
        {:ok, "  1) test issue signature (Aiur.ExampleTest)\n     test/aiur/example_test.exs:12"}
      end,
      annotations_fun: fn _, _ -> {:ok, []} end,
      jobs_fun: fn id, _ ->
        {:ok,
         [
           %{
             "name" => "test",
             "conclusion" => if(id == 201, do: "failure", else: "success"),
             "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"
           }
         ]}
      end,
      known_failure_patterns_fun: fn ->
        {:ok, [%{"title" => "Flaky test: ExampleTest :: test issue signature", "number" => nil}]}
      end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/lib/changed.ex"]} end,
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
    assert_receive {:enqueue, "PR_17", "current"}, 1_000
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:enqueue, _, _}
  end

  test "the fifth group requeue in fifteen minutes is not enqueued" do
    parent = self()

    journal = journal_path("rate-cap")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    group_branch = "pr-17-a-pr-18-b-pr-19-c-pr-20-d-pr-21-e"
    run = group_run(401, "failure", group_branch)
    now_ms = System.system_time(:millisecond)

    prs =
      for number <- 17..21,
          do: %{
            number: number,
            base: "main",
            head: "head-#{number}",
            node_id: "PR_#{number}",
            draft?: false,
            review_decision: "APPROVED",
            merge_queue_entry: nil,
            auto_merge_request: nil,
            rest: %{"head" => %{"ref" => "aiur/#{number}-work"}}
          }

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/#{group_branch}"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [run], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      now_ms: now_ms,
      live_observations_fun: fn _, _ -> {:ok, prs} end,
      job_log_fun: fn _, _ -> {:ok, "runner lost before job setup; failed test"} end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
      changed_paths_fun: fn _prs, _ -> {:ok, []} end,
      jobs_fun: fn _, _ ->
        {:ok, [%{"id" => 12, "name" => "ci gate", "conclusion" => "failure"}]}
      end,
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      enqueue_fun: fn node, head, _ ->
        send(parent, {:enqueue, node, head})
        {:ok, "entry-#{head}"}
      end
    ]

    assert :ok = MergeGroups.cancel_stale([], options)

    enqueued =
      for _ <- 1..4 do
        assert_receive {:enqueue, node, _}, 1_000
        node
      end

    assert length(enqueued) == 4
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:enqueue, _, _}
    hour = div(now_ms, 3_600_000) * 3_600_000
    hour_key = DateTime.from_unix!(hour, :millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    assert {:ok, %{^hour_key => 4}} = journal_counts(journal)
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

  defp journal_counts(path) do
    alias Aiur.LandingWatch.Journal
    Journal.merge_group_requeues_by_hour(journal_path: path)
  end

  defp journal_path(name) do
    Path.join(System.tmp_dir!(), "landing-watch-#{name}-#{System.unique_integer([:positive])}.json")
  end
end
