defmodule Aiur.LandingWatch.MergeGroupFailureRequeueTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "a recorded known non-PR failure re-enqueues the dropped approved PR once" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-flake-#{System.unique_integer([:positive])}.json"
      )

    failed = group_run(201, "failure", "pr-17-a")
    passed = group_run(202, "success", "pr-17-b")

    request = fn %{method: :get, url: url} ->
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
        {:ok, "mix test src/test/aiur/example_test.exs:12 test issue signature failed"}
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
    assert_received {:enqueue, "PR_17", "current"}
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:enqueue, _, _}
    File.rm(journal)
  end

  test "the fifth group requeue in fifteen minutes is not enqueued" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-rate-cap-#{System.unique_integer([:positive])}.json"
      )

    run = group_run(401, "failure", "pr-17-a-pr-18-b-pr-19-c-pr-20-d-pr-21-e")

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

    request = fn %{method: :get, url: url} ->
      runs = if String.contains?(url, "status=completed"), do: [run], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      now_ms: 2_000_000,
      live_observations_fun: fn _, _ -> {:ok, prs} end,
      job_log_fun: fn _, _ -> {:ok, "runner lost before job setup"} end,
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
        assert_received {:enqueue, node, _}
        node
      end

    assert length(enqueued) == 4
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:enqueue, _, _}
    assert {:ok, %{"1970-01-01T00:00:00Z" => 4}} = journal_counts(journal)
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

  defp journal_counts(path) do
    alias Aiur.LandingWatch.Journal
    Journal.merge_group_requeues_by_hour(journal_path: path)
  end
end
