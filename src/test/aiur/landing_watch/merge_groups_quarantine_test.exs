defmodule Aiur.LandingWatch.MergeGroupsQuarantineTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.Journal
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
      job_log_fun: fn _job, _opts -> {:ok, ""} end,
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

  test "main push degraded runner skips annotated failures but a healthy single flake is recorded" do
    parent = self()
    degraded_path = temp_journal("main-degraded")
    healthy_path = temp_journal("main-healthy")

    on_exit(fn ->
      Aiur.TestCleanup.rm_rf!(degraded_path)
      Aiur.TestCleanup.rm_rf!(healthy_path)
    end)

    degraded = main_entry(514)
    healthy = main_entry(515)

    degraded_log = "** (ExUnit.TimeoutError) first\n** (ExUnit.TimeoutError) second\n** (ExUnit.TimeoutError) third"
    degraded_opts = Keyword.put(main_opts(degraded_path, degraded, degraded_log), :alert_emitter, fn name, _opts -> send(parent, {:runner_degraded, name}) end)
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", degraded_opts)
    assert {:ok, degraded_state} = Journal.state(journal_path: degraded_path)
    assert Map.get(degraded_state, "failure_observations", []) == []
    assert Map.has_key?(degraded_state["flakes"], "quarantine-base-scan :: main-sha-514")

    green_opts = Keyword.put(degraded_opts, :jobs_fun, fn _, _ -> {:ok, [%{"id" => 10, "name" => "test", "conclusion" => "success"}]} end)
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", green_opts)
    assert_received {:runner_degraded, "system.pr.landing.runner_degraded"}
    refute_received {:runner_degraded, _}
    refute_received {:healthy_flake_candidate, _}

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", main_opts(healthy_path, healthy, "** (ExUnit.AssertionError) one test failed", parent))
    assert {:ok, healthy_state} = Journal.state(journal_path: healthy_path)
    assert Enum.any?(healthy_state["failure_observations"], &(&1["identity"] == "Aiur.HealthyTest :: flakes"))
    assert_received {:healthy_flake_candidate, %{module: "Aiur.HealthyTest", name: "flakes"}}
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

  test "degraded runner timeouts and partition kill file no flake tickets" do
    parent = self()
    run = failed_run(513, "pr-55-a", "https://github.com/test-org/test-repo/actions/runs/513", minutes_ago(2))
    repeated_run = failed_run(516, "pr-55-a", "https://github.com/test-org/test-repo/actions/runs/516", minutes_ago(1))
    journal = Path.join(System.tmp_dir!(), "mgq-degraded-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)

    jobs = [
      %{"check_run_id" => 1, "id" => 1, "name" => "test", "conclusion" => "failure"},
      %{"check_run_id" => 2, "id" => 2, "name" => "coverage (3/4)", "conclusion" => "failure"}
    ]

    opts = [
      journal_path: journal,
      token: "test-token",
      request_fun: fn _request -> {:ok, %{status: 200, body: []}} end,
      jobs_fun: fn _run, _opts -> {:ok, jobs} end,
      job_log_fun: fn
        %{"id" => 1}, _opts ->
          {:ok, "** (ExUnit.TimeoutError) test timed out after 60000ms\n** (ExUnit.TimeoutError) another test timed out after 60000ms\n** (ExUnit.TimeoutError) third test timed out after 60000ms"}

        %{"id" => 2}, _opts ->
          {:ok, "Error: coverage partition 3 killed at 20m time bound"}
      end,
      annotations_fun: fn _id, _opts -> {:ok, [%{"title" => "aiur-test-failure", "message" => "new-failure :: Aiur.ExampleTest :: fails", "path" => "src/test/example_test.exs"}]} end,
      flake_recorder: fn _, _, _, _ ->
        send(parent, :flake_ticket_recorded)
        :ok
      end,
      main_history_fun: fn -> [] end,
      live_observations_fun: fn _fallback, _opts -> {:ok, []} end,
      changed_paths_fun: fn _pr, _opts -> {:ok, []} end,
      commit_paths_fun: fn _sha, _opts -> {:ok, []} end,
      quarantine_list_fun: fn -> {:ok, ""} end,
      quarantine_pr_fun: fn _candidate, _ticket, _opts -> {:ok, %{number: 901}} end
    ]

    assert :ok = MergeGroupQuarantine.process_completed([run, repeated_run], [], "main", opts)
    refute_received :flake_ticket_recorded
  end

  defp minutes_ago(minutes), do: DateTime.utc_now() |> DateTime.add(-minutes * 60) |> DateTime.to_iso8601()

  defp main_opts(journal, entry, log, parent \\ self()),
    do: [
      journal_path: journal,
      main_history_fun: fn -> [entry] end,
      jobs_fun: fn _, _ -> {:ok, [%{"id" => 10, "name" => "test", "conclusion" => "failure"}]} end,
      job_log_fun: fn _, _ -> {:ok, log} end,
      annotations_fun: fn _, _ -> {:ok, []} end,
      commit_paths_fun: fn _, _ -> {:ok, []} end,
      quarantine_list_fun: fn -> {:ok, ""} end,
      flake_recorder: fn failure, _run, _passed, recorder_opts ->
        send(parent, {:healthy_flake_candidate, failure})
        recorder_opts[:issue_recorded_fun].(900)
      end,
      quarantine_pr_fun: fn _candidate, _ticket, _opts -> {:ok, %{number: 901}} end
    ]

  defp main_entry(id),
    do: %{
      sha: "main-sha-#{id}",
      completed_at: System.system_time(:millisecond),
      run_urls: ["https://github.com/test-org/test-repo/actions/runs/#{id}"],
      digest: %{
        checks: [
          %{
            id: 10,
            name: "test",
            url: "https://github.com/test-org/test-repo/actions/runs/#{id}",
            tests: [%{identity: if(id == 514, do: "Aiur.DegradedTest :: flakes", else: "Aiur.HealthyTest :: flakes"), path: nil}]
          }
        ]
      }
    }

  defp temp_journal(prefix), do: Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.json")

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
