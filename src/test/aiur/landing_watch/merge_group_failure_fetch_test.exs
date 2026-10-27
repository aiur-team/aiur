defmodule Aiur.LandingWatch.MergeGroupFailureFetchTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "a test failure in a group with no observed dropped PR is classified without a requeue" do
    failed = group_run(101, "failure", "pr-17-a-pr-19-b")
    passed = group_run(102, "success", "pr-17-a-pr-21-c")

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{failed["head_branch"]}"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [failed, passed], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    assert :ok =
             MergeGroups.cancel_stale([],
               base_branch: "main",
               token: "test-gh-token",
               request_fun: request,
               live_observations_fun: fn _, _ -> {:ok, []} end,
               changed_paths_fun: fn _, _ -> {:ok, []} end,
               annotations_fun: fn _, _ -> {:ok, []} end,
               job_log_fun: fn _, _ -> {:ok, "failed test ExampleTest regression"} end,
               jobs_fun: fn
                 101, _ ->
                   {:ok,
                    [
                      %{
                        "name" => "test",
                        "conclusion" => "failure",
                        "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"
                      }
                    ]}

                 102, _ ->
                   {:ok, [%{"name" => "test", "conclusion" => "success"}]}
               end,
               known_failure_patterns: []
             )
  end

  test "the classifier and quarantine scanner each claim a failed run once" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-run-journal-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(journal) end)
    failed = group_run(111, "failure", "pr-17-a")

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{failed["head_branch"]}"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [failed], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, []} end,
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      annotations_fun: fn _, _ -> {:ok, []} end,
      job_log_fun: fn _, _ -> {:ok, "failed test ExampleTest regression"} end,
      jobs_fun: fn id, _ ->
        send(parent, {:jobs, id})

        {:ok,
         [
           %{
             "name" => "test",
             "conclusion" => if(id == 111, do: "failure", else: "success"),
             "check_run_url" => "https://api.github.com/repos/o/r/check-runs/901"
           }
         ]}
      end,
      known_failure_patterns: []
    ]

    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:jobs, 111}
    assert_received {:jobs, 111}
    refute_received {:jobs, _}
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:jobs, _}
  end

  test "a processing error releases the completed-run claim for the next poll" do
    parent = self()

    journal =
      Path.join(
        System.tmp_dir!(),
        "landing-watch-retry-journal-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(journal) end)
    failed = group_run(121, "failure", "pr-17-a")
    calls = :atomics.new(1, [])

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{failed["head_branch"]}"}]}}

      %{method: :get, url: url} ->
        runs = if String.contains?(url, "status=completed"), do: [failed], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    options = [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, []} end,
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      annotations_fun: fn _, _ -> {:ok, []} end,
      jobs_fun: fn 121, _ ->
        send(parent, :jobs_requested)

        if :atomics.add_get(calls, 1, 1) == 1 do
          {:error, :temporary_failure}
        else
          {:ok,
           [
             %{
               "name" => "test",
               "conclusion" => "failure",
               "check_run_url" => "https://api.github.com/repos/o/r/check-runs/902"
             }
           ]}
        end
      end,
      job_log_fun: fn _, _ -> {:ok, "failed test ExampleTest regression"} end
    ]

    assert {:error, _} = MergeGroups.cancel_stale([], options)
    assert_received :jobs_requested
    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received :jobs_requested
    assert_received :jobs_requested
    refute_received :jobs_requested
  end

  defp group_run(id, conclusion, prs) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => conclusion,
      "head_branch" => "gh-readonly-queue/main/#{prs}",
      "html_url" => "https://github.com/test-org/test-repo/actions/runs/#{id}",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end
end
