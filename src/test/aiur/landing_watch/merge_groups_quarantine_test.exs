defmodule Aiur.LandingWatch.MergeGroupsQuarantineTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeGroupQuarantine
  alias Aiur.LandingWatch.MergeGroups

  test "two failed runs from unrelated PRs open one quarantine PR candidate" do
    parent = self()
    journal = Path.join(System.tmp_dir!(), "merge-group-quarantine-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)

    # Relative to now: the quarantine window is 24 hours, so fixed dates expire.
    runs = [
      failed_run(501, "pr-41-a-pr-42-b", "https://github.com/test-org/test-repo/actions/runs/501", minutes_ago(20)),
      failed_run(502, "pr-43-c-pr-44-d", "https://github.com/test-org/test-repo/actions/runs/502", minutes_ago(10))
    ]

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: Enum.map(runs, &%{"ref" => "refs/heads/#{&1["head_branch"]}"})}}

      %{method: :get, url: url} ->
        if String.contains?(url, "status=completed"),
          do: {:ok, %{status: 200, body: %{"workflow_runs" => runs}}},
          else: {:ok, %{status: 200, body: %{"workflow_runs" => []}}}
    end

    opts = [
      base_branch: "main",
      journal_path: journal,
      token: "test-gh-token",
      request_fun: request,
      live_observations_fun: fn _fallback, _opts -> {:ok, []} end,
      changed_paths_fun: fn _pr, _opts -> {:ok, []} end,
      jobs_fun: fn _run, _opts -> {:ok, [%{"check_run_id" => 1, "name" => "test", "conclusion" => "failure"}]} end,
      job_log_fun: fn _job, _opts -> {:ok, ""} end,
      annotations_fun: fn _id, _opts -> {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.ExampleTest :: flakes", "path" => "src/test/example_test.exs"}]} end,
      flake_recorder: fn _failure, _run, _passed, recorder_opts ->
        send(parent, :flake_ticket_recorded)
        recorder_opts[:issue_recorded_fun].(900)
      end,
      quarantine_pr_fun: fn candidate, ticket, _opts ->
        send(parent, {:quarantine_candidate, ticket, candidate})
        {:ok, %{number: 901}}
      end,
      cancel_fun: fn _, _ -> :ok end,
      main_history_fun: fn -> [] end
    ]

    assert :ok = MergeGroups.cancel_stale([], opts)
    assert_received :flake_ticket_recorded
    assert_received {:quarantine_candidate, 900, candidate}
    assert candidate.identity == "Aiur.ExampleTest :: flakes"
    assert Enum.map(candidate.observations, & &1.pr) |> Enum.uniq() |> length() == 4
  end

  test "changed PR paths are fetched once per PR even for a cascade failure" do
    parent = self()
    run = failed_run(511, "pr-51-a-pr-52-b", "https://github.com/test-org/test-repo/actions/runs/511", DateTime.to_iso8601(DateTime.utc_now()))
    journal = Path.join(System.tmp_dir!(), "merge-group-path-cache-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)

    opts = [
      journal_path: journal,
      changed_paths_fun: fn pr, _opts ->
        send(parent, {:changed_paths, pr})
        {:ok, []}
      end,
      jobs_fun: fn _run, _opts ->
        {:ok, [%{"check_run_id" => 1, "name" => "test", "conclusion" => "failure"}]}
      end,
      annotations_fun: fn _id, _opts ->
        {:ok,
         [
           %{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.OneTest :: fails", "path" => "test/one_test.exs"},
           %{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.TwoTest :: fails", "path" => "test/two_test.exs"}
         ]}
      end,
      flake_recorder: fn failure, _run, [], _opts ->
        send(parent, {:cascade_ticket, failure.module, failure.cascade_modules})
        :ok
      end
    ]

    assert :ok = MergeGroupQuarantine.process_completed([run], [], "main", Keyword.put(opts, :main_history_fun, fn -> [] end))
    assert_received {:changed_paths, 51}
    assert_received {:changed_paths, 52}
    refute_received {:changed_paths, _}
    assert_received {:cascade_ticket, "Aiur.OneTest", ["Aiur.TwoTest"]}
  end

  test "failed runs older than a day are skipped before fetching jobs" do
    run = failed_run(512, "pr-53-a", "https://github.com/test-org/test-repo/actions/runs/512", "2026-10-01T10:00:00Z")

    assert :ok =
             MergeGroupQuarantine.process_completed([run], [], "main",
               journal_path: Path.join(System.tmp_dir!(), "mgq-stale-#{System.unique_integer([:positive])}.json"),
               main_history_fun: fn -> [] end,
               jobs_fun: fn _run, _opts -> flunk("stale runs must not fetch jobs") end
             )
  end

  defp minutes_ago(minutes), do: DateTime.utc_now() |> DateTime.add(-minutes * 60) |> DateTime.to_iso8601()

  defp failed_run(id, branch, url, created_at) do
    %{
      "id" => id,
      "event" => "merge_group",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/#{branch}",
      "html_url" => url,
      "created_at" => created_at
    }
  end
end
