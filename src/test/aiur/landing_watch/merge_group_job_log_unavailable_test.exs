defmodule Aiur.LandingWatch.MergeGroupJobLogUnavailableTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroups

  test "a job log GitHub no longer serves raises an attention for that run and keeps routing the rest" do
    options =
      options(
        job_log_fun: fn
          %{"id" => 5010}, _ -> {:error, {:github, :http, %{status: 404}}}
          _, _ -> {:ok, "mix test src/test/aiur/changed_test.exs:12 failed"}
        end
      )

    assert :ok = MergeGroups.cancel_stale([], options)

    assert_received {:alert, "system.pr.landing.job_log_unavailable", alert}
    assert alert[:needs_attention]
    assert alert[:message] =~ "job 5010"
    assert alert[:message] =~ "run 501"
    assert_received {:rework, 18}
    refute_received {:rework, 17}

    # The degraded run stays claimed, so the next poll neither retries nor re-alerts it.
    assert :ok = MergeGroups.cancel_stale([], options)
    refute_received {:alert, _, _}
  end

  test "a transient log read error releases the claim and retries on the next poll" do
    parent = self()
    hold = {:github, :local_hold, %{reason: :github_budget_broker_timeout}}

    options =
      options(
        job_log_fun: fn _, _ ->
          send(parent, :log_read)
          {:error, hold}
        end
      )

    assert {:error, {:job_log, 5010, ^hold}} = MergeGroups.cancel_stale([], options)
    assert_received :log_read
    refute_received {:alert, _, _}

    assert {:error, {:job_log, 5010, ^hold}} = MergeGroups.cancel_stale([], options)
    assert_received :log_read
  end

  test "a plain-text job log body from GitHub is classified" do
    options = options(log_body: "mix test src/test/aiur/changed_test.exs:12 failed")

    assert :ok = MergeGroups.cancel_stale([], options)
    assert_received {:rework, 17}
    assert_received {:rework, 18}
    refute_received {:alert, _, _}
  end

  defp options(overrides) do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "landing-watch-job-log-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    log_body = Keyword.get(overrides, :log_body, "")

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/gh-readonly-queue/main/pr-17-a"}, %{"ref" => "refs/heads/gh-readonly-queue/main/pr-18-b"}]}}

      %{method: :get, url: url} ->
        cond do
          String.contains?(url, "/actions/jobs/") ->
            {:ok, %{status: 200, body: log_body}}

          String.contains?(url, "status=completed") ->
            {:ok, %{status: 200, body: %{"workflow_runs" => [group_run(501, "pr-17-a"), group_run(502, "pr-18-b")]}}}

          true ->
            {:ok, %{status: 200, body: %{"workflow_runs" => []}}}
        end
    end

    [
      base_branch: "main",
      token: "test-gh-token",
      request_fun: request,
      journal_path: journal,
      live_observations_fun: fn _, _ -> {:ok, [pr(17), pr(18)]} end,
      jobs_fun: fn run_id, _ -> {:ok, [%{"id" => run_id * 10, "name" => "test", "conclusion" => "failure"}]} end,
      changed_paths_fun: fn _, _ -> {:ok, ["src/test/aiur/changed_test.exs"]} end,
      known_failure_patterns: [],
      repo_fun: fn -> {:ok, {"aiur-team", "aiur"}} end,
      alert_emitter: fn name, opts -> send(parent, {:alert, name, opts}) end,
      rework_fun: fn observation, _failures, _opts ->
        send(parent, {:rework, observation.number})
        :ok
      end
    ] ++ Keyword.take(overrides, [:job_log_fun])
  end

  defp group_run(id, prs) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/#{prs}"
    }
  end

  defp pr(number) do
    %{
      number: number,
      base: "main",
      head: "current",
      node_id: "PR_#{number}",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/#{number}-work"}}
    }
  end
end
