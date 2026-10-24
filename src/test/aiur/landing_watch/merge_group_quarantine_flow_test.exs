defmodule Aiur.LandingWatch.MergeGroupQuarantineFlowTest do
  # Fixtures are shaped like the 2026-10-18 flakes that each dropped approved PRs from the queue.
  use ExUnit.Case, async: true

  alias Aiur.CI.FailureDigest
  alias Aiur.LandingWatch.{Journal, MergeGroupFailureProcessor, MergeGroupQuarantine, MergeGroups}

  @reaper "Aiur.Claude.Repl.ReaperTest :: stop_session/1 reports cleanup unknown while the process group remains alive"
  @reaper_path "src/test/aiur/claude/repl/reaper_test.exs"
  @live_pack "AiurWeb.BuildOrder.PlanningSource.LivePackProgressTest :: uses current poll labels without waiting on the mailbox and drops stale labels"

  setup do
    journal = Path.join(System.tmp_dir!(), "quarantine-flow-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(journal) end)
    %{journal: journal}
  end

  test "a flake seen in two polls survives the per-poll journal prune and is quarantined", %{journal: journal} do
    opts = opts(journal, self())
    first = group_run(39_136_853_814, "pr-4995-aaa", 30)
    second = group_run(39_139_000_001, "pr-5108-bbb", 10)

    assert :ok = MergeGroupQuarantine.process_completed([first], [], "main", opts)
    refute_received {:quarantine_pr, _, _}

    # Every poll starts by pruning journal entries for heads that left the queue.
    assert :ok = Journal.retain_current_heads([], opts)

    assert :ok = MergeGroupQuarantine.process_completed([first, second], [], "main", opts)
    assert_received {:flake_ticket, @reaper, 39_139_000_001}
    assert_received {:quarantine_pr, 5200, candidate}
    assert candidate.identity == @reaper
    assert candidate.observations |> Enum.map(& &1.pr) |> Enum.sort() == [4995, 5108]
  end

  test "a touched merge-group failure reaches neither Detector.repeated nor the quarantined-run reader", %{journal: journal} do
    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]
    opts = opts(journal, self()) |> Keyword.put(:changed_paths_fun, fn _pr, _opts -> {:ok, [@reaper_path]} end)

    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    assert {:ok, %{"failure_observations" => [], "failure_metric_evidence" => metric_rows}} = Journal.state(opts)
    assert length(metric_rows) == 2
    assert Enum.all?(metric_rows, &(&1["touched"] == true))
    assert MergeGroupQuarantine.quarantined_run_ids(opts) == []
    refute_received {:flake_ticket, _, _}
    refute_received {:quarantine_pr, _, _}
  end

  test "one shard attempt failing in two modules records one cascade ticket and opens no quarantine", %{journal: journal} do
    parent = self()

    opts =
      journal
      |> opts(parent)
      |> Keyword.put(:annotations_fun, fn _id, _opts ->
        {:ok,
         [
           %{"title" => "aiur-test-failure", "path" => "src/test/first_test.exs", "message" => "new-failure :: Aiur.FirstTest :: first failure"},
           %{"title" => "aiur-test-failure", "path" => "src/test/first_test.exs", "message" => "new-failure :: Aiur.FirstTest :: second failure"},
           %{"title" => "aiur-test-failure", "path" => "src/test/second_test.exs", "message" => "new-failure :: Aiur.SecondTest :: collateral failure"}
         ]}
      end)

    assert :ok = MergeGroupQuarantine.process_completed([group_run(39_140_000_001, "pr-5328-cascade", 5)], [], "main", opts)
    assert_received {:flake_ticket, "Aiur.FirstTest :: first failure", 39_140_000_001, ["Aiur.SecondTest"]}
    refute_received {:flake_ticket, _, _}
    refute_received {:quarantine_pr, _, _}
  end

  test "one untouched base-branch failure is quarantined immediately", %{journal: journal} do
    main_run = "https://github.com/test-org/test-repo/actions/runs/39126982641/job/117676517063"
    test = %{identity: @live_pack, path: "src/test/aiur_web/build_order/planning_source/live_pack_progress_test.exs", classification: :new_failure}
    digest = %FailureDigest{checks: [%{name: "coverage (1/4)", url: main_run, tests: [test]}], tests: [test]}
    red = %{sha: "fb9f75853ec58c7c402947274faa1562939d5dff", completed_at: minutes_ago_ms(15), run_urls: [], digest: digest}
    checked_paths = ["src/lib/aiur/unrelated_change.ex"]

    opts =
      journal
      |> opts(self())
      |> Keyword.put(:main_history_fun, fn -> [red] end)
      |> Keyword.put(:commit_paths_fun, fn _sha, _opts -> {:ok, checked_paths} end)

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts)
    assert_received {:flake_ticket, @live_pack, 39_126_982_641}
    assert_received {:quarantine_pr, 5200, %{identity: @live_pack, observations: [%{run_url: ^main_run}]}}
    assert {:ok, [observation]} = Journal.failure_observations(opts)
    assert observation["checked_paths"] == checked_paths
    assert observation["touched"] == false
  end

  test "a base failure in a test touched by that push does not quarantine", %{journal: journal} do
    test = %{identity: @live_pack, path: "src/test/aiur_web/build_order/planning_source/live_pack_progress_test.exs", classification: :new_failure}
    digest = %FailureDigest{checks: [%{name: "coverage (1/4)", url: "https://github.com/test-org/test-repo/actions/runs/39126982641/job/117676517063", tests: [test]}], tests: [test]}
    red = %{sha: "fb9f75853ec58c7c402947274faa1562939d5dff", completed_at: minutes_ago_ms(15), run_urls: [], digest: digest}
    opts = journal |> opts(self()) |> Keyword.put(:main_history_fun, fn -> [red] end) |> Keyword.put(:commit_paths_fun, fn _sha, _ -> {:ok, [test.path]} end)

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts)
    refute_received {:flake_ticket, _, _}
    refute_received {:quarantine_pr, _, _}
  end

  test "a transient GitHub error retries the quarantine PR next poll without filing the ticket again", %{journal: journal} do
    parent = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    flaky_pr = fn candidate, ticket, _opts ->
      send(parent, {:quarantine_pr, ticket, candidate})

      if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0,
        do: {:error, {:github, :local_hold, %{reason: :github_budget_broker_timeout}}},
        else: {:ok, %{"number" => 5201}}
    end

    opts = journal |> opts(parent) |> Keyword.put(:quarantine_pr_fun, flaky_pr)
    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]

    assert {:error, {:github, :local_hold, _}} = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    assert_received {:flake_ticket, @reaper, _run}
    assert_received {:quarantine_pr, 5200, _}

    # Backoff: an immediate poll does not retry; one after the first 1-minute delay does.
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    refute_received {:quarantine_pr, _, _}
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", Keyword.put(opts, :quarantine_now_ms, System.system_time(:millisecond) + 61_000))
    assert_received {:quarantine_pr, 5200, %{identity: @reaper}}
    refute_received {:flake_ticket, _, _}
    assert Enum.sort(MergeGroupQuarantine.quarantined_run_ids(opts)) == [39_136_853_814, 39_139_000_001]
  end

  test "approved PRs a quarantined test dropped are requeued, not reworked", %{journal: journal} do
    parent = self()
    base = "main-#{System.unique_integer([:positive])}"
    first = group_run(39_136_853_814, "pr-41-aaa", 30, base)
    second = group_run(39_139_000_001, "pr-43-bbb", 10, base)
    prs = [approved_pr(41, base), approved_pr(43, base)]

    request = fn
      %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
        {:ok, %{status: 200, body: [%{"ref" => "refs/heads/#{first["head_branch"]}"}, %{"ref" => "refs/heads/#{second["head_branch"]}"}]}}

      %{method: :get, url: url} ->
        runs = if url =~ "event=merge_group" and url =~ "status=completed", do: [first, second], else: []
        {:ok, %{status: 200, body: %{"workflow_runs" => runs}}}
    end

    opts =
      journal
      |> opts(parent)
      |> Keyword.merge(
        base_branch: base,
        request_fun: request,
        live_observations_fun: fn _, _ -> {:ok, prs} end,
        job_log_fun: fn _, _ -> {:ok, "mix test #{@reaper_path}:212 test failure"} end,
        recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
        known_failure_patterns: [],
        approved_fun: fn _, _ -> {:ok, true} end,
        revalidate_fun: fn _, _, _ -> :ok end,
        attribution_fun: fn _ -> {:ok, :clean} end,
        comment_fun: fn _, _, _ -> :ok end,
        enqueue_fun: fn node, _head, _ ->
          send(parent, {:enqueue, node})
          {:ok, "entry-#{node}"}
        end,
        rework_fun: fn observation, _failures, _opts ->
          send(parent, {:rework, observation.number})
          :ok
        end,
        cancel_fun: fn _, _ -> :ok end
      )

    # Poll 1 saw only the first failure: one group is not yet a flake, so its PR went to rework.
    assert :ok = MergeGroupQuarantine.process_completed([first], prs, base, opts)
    assert :ok = MergeGroupFailureProcessor.process_completed([first], prs, base, opts)
    assert_received {:rework, 41}

    # Poll 2: the second unrelated failure quarantines the test.
    assert :ok = MergeGroups.cancel_stale([], opts)
    assert_received {:quarantine_pr, 5200, %{identity: @reaper}}
    assert_received {:enqueue, "PR_41"}
    assert_received {:enqueue, "PR_43"}
    refute_received {:rework, 43}
  end

  defp opts(journal, parent) do
    [
      base_branch: "main",
      token: "test-gh-token",
      journal_path: journal,
      main_history_fun: fn -> [] end,
      quarantine_list_fun: fn -> {:ok, ""} end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, []} end,
      job_log_fun: fn _, _ -> {:ok, ""} end,
      request_fun: fn
        %{url: "https://api.github.com/repos/test-org/test-repo/git/matching-refs/heads/gh-readonly-queue/" <> _} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{"ref" => "refs/heads/gh-readonly-queue/main/pr-4995-aaa"},
               %{"ref" => "refs/heads/gh-readonly-queue/main/pr-5108-bbb"}
             ]
           }}

        %{method: :get, url: url} ->
          cond do
            url =~ "/commits?" -> {:ok, %{status: 200, body: [%{"sha" => "fixsha"}]}}
            url =~ "/compare/" -> {:ok, %{status: 200, body: %{"status" => "behind"}}}
            true -> flunk("unexpected request #{url}")
          end
      end,
      changed_paths_fun: fn _pr, _opts -> {:ok, ["src/lib/aiur/unrelated.ex"]} end,
      commit_paths_fun: fn _sha, _opts -> {:ok, ["src/lib/aiur/unrelated.ex"]} end,
      jobs_fun: fn _run, _opts -> {:ok, [%{"id" => 117_701_756_559, "check_run_id" => 117_701_756_559, "name" => "coverage (2/4)", "conclusion" => "failure"}]} end,
      annotations_fun: fn _id, _opts ->
        {:ok,
         [
           %{"title" => "", "annotation_level" => "failure", "path" => ".github", "message" => "coverage partition 2 failed with status 2; full log follows in the next step"},
           %{"title" => "aiur-test-failure", "annotation_level" => "failure", "path" => @reaper_path, "message" => "new-failure :: " <> @reaper}
         ]}
      end,
      flake_recorder: fn failure, run, [], recorder_opts ->
        ticket = {"#{failure.module} :: #{failure.name}", run["id"]}

        if Map.has_key?(failure, :cascade_modules),
          do: send(parent, {:flake_ticket, elem(ticket, 0), elem(ticket, 1), failure.cascade_modules}),
          else: send(parent, {:flake_ticket, elem(ticket, 0), elem(ticket, 1)})

        if is_function(recorder_opts[:issue_recorded_fun], 1), do: recorder_opts[:issue_recorded_fun].(5200), else: :ok
      end,
      quarantine_pr_fun: fn candidate, ticket, _opts ->
        send(parent, {:quarantine_pr, ticket, candidate})
        {:ok, %{"number" => 5201}}
      end
    ]
  end

  defp approved_pr(number, base) do
    %{
      number: number,
      base: base,
      head: "head-#{number}",
      node_id: "PR_#{number}",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/#{number}-work"}}
    }
  end

  defp group_run(id, branch, minutes_ago, base \\ "main") do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => "failure",
      "head_sha" => "group-head-#{id}",
      "head_branch" => "gh-readonly-queue/#{base}/#{branch}",
      "html_url" => "https://github.com/test-org/test-repo/actions/runs/#{id}",
      "created_at" => DateTime.utc_now() |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601()
    }
  end

  defp minutes_ago_ms(minutes), do: System.system_time(:millisecond) - minutes * 60_000
end
