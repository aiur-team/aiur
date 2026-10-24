defmodule Aiur.LandingWatch.MergeGroupBlameTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Aiur.LandingWatch.Journal
  alias Aiur.LandingWatch.MergeGroups

  test "only the PR touching the failing test is sent to rework" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "merge-group-blame-#{System.unique_integer([:positive])}.json")

    run = %{
      "id" => 908,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/pr-17-a-pr-18-b-pr-19-c"
    }

    request = fn %{url: url} ->
      if String.contains?(url, "matching-refs") do
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{run["head_branch"]}"}]}}
      else
        runs = if String.contains?(url, "status=completed"), do: [run], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
      end
    end

    prs =
      for number <- 17..19 do
        %{
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
      end

    opts = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: path,
      live_observations_fun: fn _, _ -> {:ok, prs} end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => 910, "name" => "test", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ ->
        {:ok,
         "  1) test changed behavior (Aiur.ChangedTest)\n     test/aiur/changed_test.exs:12\n\n  2) test second behavior (Aiur.SecondChangedTest)\n     test/aiur/second_changed_test.exs:8\n\nwarning: test/aiur/ignored_test.exs:3:3"}
      end,
      changed_paths_fun: fn number, _ ->
        paths = ["src/test/aiur/changed_test.exs", "src/test/aiur/second_changed_test.exs"]
        {:ok, if(number == 18, do: paths, else: [])}
      end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
      known_failure_patterns: [],
      rework_fun: fn observation, _, _ ->
        send(parent, {:rework, observation.number})
        :ok
      end,
      enqueue_fun: fn _, _, _ -> {:ok, "entry"} end,
      approved_fun: fn _, _ -> {:ok, true} end,
      revalidate_fun: fn _, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end
    ]

    assert :ok = MergeGroups.cancel_stale([], opts)
    assert_received {:rework, 18}
    refute_received {:rework, 17}
    refute_received {:rework, 19}
    assert {:ok, rows} = Journal.failure_observations(journal_path: path)
    assert Enum.any?(rows, &(&1["identity"] == "merge-group-blame:908" and &1["decision"] == "pr_caused"))
    assert {:ok, true} = Journal.merge_group_head_held?(18, "head-18", journal_path: path)
    assert {:ok, false} = Journal.merge_group_head_held?(18, "next-head-18", journal_path: path)
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a second innocent failure dequeues an unmergeable queue head" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "merge-group-unmergeable-#{System.unique_integer([:positive])}.json")
    {:ok, run_id} = Agent.start_link(fn -> 930 end)

    run = fn ->
      completed = DateTime.utc_now()

      %{
        "id" => Agent.get(run_id, & &1),
        "event" => "merge_group",
        "status" => "completed",
        "conclusion" => "failure",
        "head_branch" => "gh-readonly-queue/main/pr-17-a-pr-18-b-pr-19-c",
        "created_at" => DateTime.to_iso8601(completed),
        "started_at" => DateTime.add(completed, -60, :second) |> DateTime.to_iso8601(),
        "completed_at" => DateTime.to_iso8601(completed)
      }
    end

    request = fn %{url: url} ->
      if String.contains?(url, "matching-refs") do
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{run.()["head_branch"]}"}]}}
      else
        {:ok, %{status: 200, body: %{"workflow_runs" => if(String.contains?(url, "status=completed"), do: [run.()], else: [])}}}
      end
    end

    pr = %{
      number: 17,
      base: "main",
      head: "same-head",
      node_id: "PR_17",
      draft?: false,
      review_decision: "APPROVED",
      mergeable: "MERGEABLE",
      merge_state_status: "CLEAN",
      merge_queue_entry: %{"id" => "entry-17", "state" => "UNMERGEABLE"},
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}}
    }

    prs = [pr | for(number <- 18..19, do: %{pr | number: number, head: "head-#{number}", node_id: "PR_#{number}", merge_queue_entry: nil})]

    opts = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: path,
      live_observations_fun: fn _, _ -> {:ok, prs} end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => 931, "name" => "test", "conclusion" => "failure", "check_run_url" => "https://api.github.com/repos/o/r/check-runs/931"}]} end,
      job_log_fun: fn _, _ -> {:ok, "  1) test known regression (Aiur.KnownTest)\n     test/aiur/known_test.exs:12"} end,
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      annotations_fun: fn _, _ -> {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.KnownTest :: test known regression", "path" => "src/test/aiur/known_test.exs"}]} end,
      main_history_fun: fn -> [] end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, ["src/test/aiur/known_test.exs"]} end,
      known_failure_patterns: [],
      unmergeable_revalidate_fun: fn _, _ -> :ok end,
      dequeue_fun: fn node, _ ->
        send(parent, {:dequeue, node})
        :ok
      end,
      queue_free_revalidate_fun: fn _, _ -> :ok end,
      enqueue_fun: fn node, head, _ ->
        send(parent, {:enqueue, node, head})
        {:ok, "new-entry"}
      end,
      revalidate_fun: fn _, _, _ -> :ok end,
      approved_fun: fn _, _ -> {:ok, true} end,
      ticket_state_fun: fn _issue, _ -> {:ok, "ci-wait"} end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      comment_fun: fn _, _, _ -> :ok end,
      rework_fun: fn observation, _, _ ->
        send(parent, {:rework, observation.number})
        :ok
      end
    ]

    assert :ok = MergeGroups.cancel_stale([], opts)
    assert_received {:dequeue, "PR_17"}
    assert_received {:enqueue, "PR_17", "same-head"}
    assert_received {:enqueue, "PR_18", "head-18"}
    assert_received {:enqueue, "PR_19", "head-19"}
    assert {:ok, observations} = Journal.failure_observations(journal_path: path)
    assert Enum.count(observations, &(&1["identity"] == "Aiur.KnownTest :: test known regression")) == 3
    assert Enum.count(observations, &(&1["identity"] == "merge-group-blame:930" and &1["decision"] == "innocent_requeued")) == 1
    refute_received {:rework, _}
    Agent.update(run_id, &(&1 + 1))
    assert :ok = MergeGroups.cancel_stale([], opts)
    refute_received {:dequeue, _}
    assert_received {:rework, 17}
    assert_received {:rework, 18}
    assert_received {:rework, 19}
    Agent.stop(run_id)
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "a failed evidence fetch logs fallback and uses legacy PR routing" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "merge-group-fallback-#{System.unique_integer([:positive])}.json")
    run = %{"id" => 940, "event" => "merge_group", "status" => "completed", "conclusion" => "failure", "head_branch" => "gh-readonly-queue/main/pr-17-a"}

    request = fn %{url: url} ->
      if String.contains?(url, "matching-refs") do
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{run["head_branch"]}"}]}}
      else
        {:ok, %{status: 200, body: %{"workflow_runs" => if(String.contains?(url, "status=completed"), do: [run], else: [])}}}
      end
    end

    pr = %{
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

    opts = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: path,
      live_observations_fun: fn _, _ -> {:ok, [pr]} end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => 941, "name" => "test", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ -> {:ok, "  1) test changed behavior (Aiur.ChangedTest)\n     test/aiur/changed_test.exs:12"} end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/test/aiur/changed_test.exs"]} end,
      recent_main_failure_paths_fun: fn _, _ -> {:error, :offline} end,
      rework_fun: fn observation, _, _ ->
        send(parent, {:rework, observation.number})
        :ok
      end
    ]

    log = capture_log(fn -> assert :ok = MergeGroups.cancel_stale([], opts) end)
    assert log =~ "merge-group blame evidence unavailable"
    assert log =~ "merge-group blame evidence fetch failed; using legacy routing"
    assert_received {:rework, 17}
    Aiur.TestCleanup.rm_rf!(path)
  end

  test "the journal counts repeated failures against the same PR head" do
    path = Path.join(System.tmp_dir!(), "merge-group-blame-attempt-#{System.unique_integer([:positive])}.json")
    opts = [journal_path: path]

    assert {:ok, 1} = Journal.record_merge_group_blame_attempt(18, "same-head", opts)
    assert {:ok, 2} = Journal.record_merge_group_blame_attempt(18, "same-head", opts)
    assert {:ok, 1} = Journal.record_merge_group_blame_attempt(18, "new-head", opts)

    Aiur.TestCleanup.rm_rf!(path)
  end
end
