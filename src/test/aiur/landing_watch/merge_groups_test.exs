defmodule Aiur.LandingWatch.MergeGroupsTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "only active merge-group runs without a live PR entry are cancelled" do
    parent = self()

    runs = [
      %{"id" => 31, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-3-aaa"},
      %{"id" => 32, "event" => "merge_group", "status" => "queued", "head_branch" => "gh-readonly-queue/main/pr-4-bbb"},
      %{"id" => 33, "event" => "merge_group", "status" => "completed", "head_branch" => "gh-readonly-queue/main/pr-5-ccc"},
      %{"id" => 34, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-3-aaa-pr-4-bbb"}
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    observations = [%{number: 3, base: "main", merge_queue_entry: %{"id" => "entry-3"}}]

    assert :ok = MergeGroups.cancel_stale(observations, base_branch: "main", request_fun: request, live_observations_fun: fn _, _ -> {:ok, observations} end)
    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/32/cancel"}
    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/34/cancel"}
    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/31/cancel"}
  end

  test "an active run built before the currently queued PR head is cancelled" do
    parent = self()

    runs = [
      %{"id" => 41, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-3-aaa", "created_at" => "2026-10-13T23:59:00Z"},
      %{"id" => 42, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-3-aaa", "created_at" => "2026-10-14T00:01:00Z"}
    ]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    observations = [
      %{number: 3, base: "main", head: "head-current", head_committed_at: "2026-10-14T00:00:00Z", merge_queue_entry: %{"id" => "entry-new", "pullRequest" => %{"headRefOid" => "head-current"}}}
    ]

    assert :ok = MergeGroups.cancel_stale(observations, base_branch: "main", request_fun: request, live_observations_fun: fn _, _ -> {:ok, observations} end)
    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/41/cancel"}
    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/42/cancel"}
  end

  test "the stale-run census queries active and completed statuses separately" do
    parent = self()
    historical = Enum.map(1..501, &%{"id" => &1, "event" => "merge_group", "status" => "completed", "head_branch" => "gh-readonly-queue/main/pr-#{&1}-old"})

    request = fn
      %{method: :get, url: url} ->
        send(parent, {:census, url})

        runs =
          if String.contains?(url, "status=in_progress"),
            do: [%{"id" => 900, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-900-old"}],
            else: historical

        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    assert :ok = MergeGroups.cancel_stale([], base_branch: "main", request_fun: request, live_observations_fun: fn _, _ -> {:ok, []} end)

    urls =
      for _ <- 1..5 do
        assert_received {:census, url}
        url
      end

    assert Enum.all?(urls, &String.contains?(&1, "event=merge_group"))
    assert Enum.any?(urls, &String.contains?(&1, "status=queued"))
    assert Enum.any?(urls, &String.contains?(&1, "status=in_progress"))
    assert Enum.any?(urls, &String.contains?(&1, "status=waiting"))
    assert Enum.any?(urls, &String.contains?(&1, "status=requested"))
    assert Enum.any?(urls, &String.contains?(&1, "status=completed"))
    assert_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/900/cancel"}
    refute_received {:cancel, "https://api.github.com/repos/test-org/test-repo/actions/runs/501/cancel"}
  end

  test "queue is re-observed after the active-run census before cancelling" do
    parent = self()
    runs = [%{"id" => 91, "event" => "merge_group", "status" => "in_progress", "head_branch" => "gh-readonly-queue/main/pr-9-abc", "created_at" => "2026-10-14T00:01:00Z"}]

    request = fn
      %{method: :get} ->
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}

      %{method: :post, url: url} ->
        send(parent, {:cancel, url})
        {:ok, %{status: 202, body: %{}}}
    end

    newly_enqueued = [%{number: 9, base: "main", head: "head-now", head_committed_at: "2026-10-14T00:00:00Z", merge_queue_entry: %{"id" => "entry", "pullRequest" => %{"headRefOid" => "head-now"}}}]

    assert :ok = MergeGroups.cancel_stale([], base_branch: "main", request_fun: request, live_observations_fun: fn _, _ -> {:ok, newly_enqueued} end)
    refute_received {:cancel, _}
  end

  test "a test failure is recorded only when the same test job passed in another group containing its PR" do
    parent = self()
    failed = group_run(101, "failure", "pr-17-a-pr-19-b")
    passed = group_run(102, "success", "pr-17-a-pr-21-c")

    request = fn %{method: :get, url: url} ->
      runs = if String.contains?(url, "status=completed"), do: [failed, passed], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    assert :ok =
             MergeGroups.cancel_stale([],
               base_branch: "main",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, []} end,
               jobs_fun: fn
                 101, _ -> {:ok, [%{"name" => "test", "conclusion" => "failure", "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"}]}
                 102, _ -> {:ok, [%{"name" => "test", "conclusion" => "success"}]}
               end,
               annotations_fun: fn 901, _ ->
                 {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: ExampleTest :: flakes", "raw_details" => "assertion expected :ok, got :error", "annotation_level" => "failure"}]}
               end,
               flake_recorder: fn failure, run, prs, _ ->
                 send(parent, {:flake, failure, run["id"], prs})
                 :ok
               end
             )

    assert_received {:flake, %{module: "ExampleTest", name: "flakes", job: "test", excerpt: "assertion expected :ok, got :error"}, 101, [17]}
  end

  test "a completed failed run is fetched once across repeated polls" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "landing-watch-run-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    failed = group_run(111, "failure", "pr-17-a")
    passed = group_run(112, "success", "pr-17-b")

    request = fn %{method: :get, url: url} ->
      runs = if String.contains?(url, "status=completed"), do: [failed, passed], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, []} end,
      jobs_fun: fn id, _ ->
        send(parent, {:jobs, id})
        {:ok, [%{"name" => "test", "conclusion" => if(id == 111, do: "failure", else: "success"), "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"}]}
      end,
      annotations_fun: fn id, _ ->
        send(parent, {:annotations, id})
        {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: ExampleTest :: flakes", "annotation_level" => "failure"}]}
      end,
      flake_recorder: fn _, _, _, _ -> :ok end
    ]

    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:jobs, 111}
    assert_received {:annotations, 901}
    assert_received {:jobs, 112}

    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:jobs, _}
    refute_received {:annotations, _}
  end

  test "a processing error releases the completed-run claim for the next poll" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "landing-watch-retry-journal-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    failed = group_run(121, "failure", "pr-17-a")
    calls = :atomics.new(1, [])

    request = fn %{method: :get, url: url} ->
      runs = if String.contains?(url, "status=completed"), do: [failed], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, []} end,
      jobs_fun: fn 121, _ ->
        send(parent, :jobs_requested)

        if :atomics.add_get(calls, 1, 1) == 1 do
          {:error, :temporary_failure}
        else
          {:ok, [%{"name" => "test", "conclusion" => "failure", "check_run_url" => "https://api.github.com/repos/o/r/check-runs/902"}]}
        end
      end,
      annotations_fun: fn _, _ -> {:ok, []} end,
      flake_recorder: fn _, _, _, _ -> :ok end
    ]

    assert {:error, _} = MergeGroups.cancel_stale([], options)
    assert_received :jobs_requested
    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received :jobs_requested
  end

  test "a recorded merge-group flake re-enqueues the dropped approved PR once" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "landing-watch-flake-#{System.unique_integer([:positive])}.json")
    failed = group_run(201, "failure", "pr-17-a")
    passed = group_run(202, "success", "pr-17-b")

    request = fn %{method: :get, url: url} ->
      runs = if String.contains?(url, "status=completed"), do: [failed, passed], else: []
      {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    pr = %{number: 17, base: "main", head: "current", node_id: "PR_17", draft?: false, review_decision: "APPROVED", merge_queue_entry: nil, auto_merge_request: nil}

    options = [
      base_branch: "main",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, [pr]} end,
      jobs_fun: fn id, _ -> {:ok, [%{"name" => "test", "conclusion" => if(id == 201, do: "failure", else: "success"), "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"}]} end,
      annotations_fun: fn _, _ -> {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: ExampleTest :: flakes", "annotation_level" => "failure"}]} end,
      flake_recorder: fn _, _, _, _ -> :ok end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
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

  defp group_run(id, conclusion, prs) do
    %{"id" => id, "event" => "merge_group", "status" => "completed", "conclusion" => conclusion, "head_branch" => "gh-readonly-queue/main/#{prs}"}
  end
end
