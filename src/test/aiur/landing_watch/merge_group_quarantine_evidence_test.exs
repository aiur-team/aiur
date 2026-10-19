defmodule Aiur.LandingWatch.MergeGroupQuarantineEvidenceTest do
  # What must NOT be quarantined, and how failed steps back off. Fixtures follow the 2026-10-18 failures.
  use ExUnit.Case, async: true

  alias Aiur.CI.FailureDigest
  alias Aiur.LandingWatch.MergeGroupQuarantine

  @reaper "Aiur.Claude.Repl.ReaperTest :: stop_session/1 reports cleanup unknown while the process group remains alive"
  @reaper_path "src/test/aiur/claude/repl/reaper_test.exs"
  @main_run "https://github.com/test-org/test-repo/actions/runs/39136290707/job/117701756559"

  setup do
    journal = Path.join(System.tmp_dir!(), "quarantine-evidence-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(journal) end)
    %{journal: journal}
  end

  test "a main failure whose commit changed the test's lib file is not quarantined, even after a rerun passes", %{journal: journal} do
    opts =
      journal
      |> opts(self())
      |> Keyword.merge(main_history_fun: fn -> [red_entry(15)] end, commit_paths_fun: fn _sha, _ -> {:ok, ["src/lib/aiur/claude/repl/reaper.ex"]} end)

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts)
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :main_history_fun, fn -> [rerun_green(15)] end))
    refute_received {:flake_ticket, _, _}
    refute_received {:quarantine_pr, _, _}
  end

  test "only a passing rerun of the failing commit makes a main failure a flake", %{journal: journal} do
    opts = journal |> opts(self()) |> Keyword.put(:main_history_fun, fn -> [red_entry(15)] end)

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts)
    refute_received {:quarantine_pr, _, _}

    # A later run whose annotations could not be read proves no pass.
    unknown = %{sha: "unknown7", completed_at: minutes_ago_ms(7), run_urls: [], digest: %FailureDigest{checks: [%{id: nil, name: "coverage (2/4)", url: @main_run, tests: :unknown}], tests: :unknown}}
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :main_history_fun, fn -> [red_entry(15), unknown] end))
    refute_received {:quarantine_pr, _, _}

    # A later green commit may be the fix of a regression: not evidence.
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :main_history_fun, fn -> [red_entry(15), green_entry(5)] end))
    refute_received {:quarantine_pr, _, _}

    # The rerun of the failing commit passes the test: now it is a flake.
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :main_history_fun, fn -> [rerun_green(15), green_entry(5)] end))
    assert_received {:quarantine_pr, 5200, %{identity: @reaper}}
  end

  test "two unrelated merge-group failures are not quarantined while the newest main run fails the test", %{journal: journal} do
    opts = journal |> opts(self()) |> Keyword.put(:main_history_fun, fn -> [green_entry(60), red_entry(1)] end)
    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]

    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    refute_received {:quarantine_pr, _, _}
  end

  test "a regression red on consecutive main commits and then fixed is not quarantined", %{journal: journal} do
    opts = journal |> opts(self()) |> Keyword.put(:main_history_fun, fn -> [red_entry(20), red_entry(15)] end)
    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", opts)

    assert :ok = MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :main_history_fun, fn -> [red_entry(20), red_entry(15), green_entry(5)] end))
    refute_received {:quarantine_pr, _, _}
  end

  test "merge-group failures recorded while main was red do not count once the fix lands", %{journal: journal} do
    opts = journal |> opts(self()) |> Keyword.put(:main_history_fun, fn -> [red_entry(40), red_entry(20)] end)
    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    refute_received {:quarantine_pr, _, _}

    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", Keyword.put(opts, :main_history_fun, fn -> [red_entry(40), red_entry(20), green_entry(2)] end))
    refute_received {:quarantine_pr, _, _}
  end

  test "a merge-group PR that changed the test's mirrored lib file excludes that failure", %{journal: journal} do
    changed = fn
      4995, _ -> {:ok, ["src/lib/aiur/claude/repl/reaper.ex"]}
      _pr, _ -> {:ok, ["src/lib/aiur/unrelated.ex"]}
    end

    opts = journal |> opts(self()) |> Keyword.put(:changed_paths_fun, changed)
    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]

    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)
    refute_received {:quarantine_pr, _, _}
  end

  test "a failed read while scanning a red main commit backs off instead of repeating every poll", %{journal: journal} do
    parent = self()
    t0 = System.system_time(:millisecond)

    opts =
      journal
      |> opts(parent)
      |> Keyword.merge(
        main_history_fun: fn -> [red_entry(15)] end,
        commit_paths_fun: fn _sha, _ ->
          send(parent, :commit_read)
          {:error, {:github, :local_hold, %{reason: :github_budget_broker_timeout}}}
        end
      )

    for offset <- [0, 1_000, 2_000, 30_000, 59_000], do: MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :quarantine_now_ms, t0 + offset))
    assert_received :commit_read
    refute_received :commit_read

    MergeGroupQuarantine.process_completed([], [], "main", Keyword.put(opts, :quarantine_now_ms, t0 + 61_000))
    assert_received :commit_read
  end

  test "an OrchestratorGuard failure files evidence on one guard ticket and quarantines nothing", %{journal: journal} do
    parent = self()

    guard = %{
      "title" => "aiur-guard-failure",
      "annotation_level" => "failure",
      "path" => ".github",
      "message" => "orchestrator-guard :: AiurWeb.BuildOrder.PlanningSource.LivePackProgressTest: test uses current poll labels without waiting on the mailbox and drops stale labels (down)"
    }

    main_check = %{id: 117_676_517_063, name: "coverage (1/4)", url: "https://github.com/test-org/test-repo/actions/runs/39126982641/job/117676517063", tests: []}
    main_entry = %{sha: "fb9f75853ec58c7c402947274faa1562939d5dff", completed_at: minutes_ago_ms(15), run_urls: [], digest: %FailureDigest{checks: [main_check], tests: []}}

    opts =
      journal
      |> opts(parent)
      |> Keyword.merge(
        main_history_fun: fn -> [main_entry] end,
        annotations_fun: fn _id, _ -> {:ok, [guard]} end,
        flake_recorder: fn failure, run, [], _ ->
          send(parent, {:guard_ticket, "#{failure.module} :: #{failure.name}", run["id"], failure.excerpt})
          :ok
        end
      )

    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]
    assert :ok = MergeGroupQuarantine.process_completed(runs, [], "main", opts)

    guard_identity = "Aiur.TestSupport.OrchestratorGuard :: plain ExUnit tests broke Aiur.Orchestrator"
    assert_received {:guard_ticket, ^guard_identity, 39_126_982_641, excerpt}
    assert excerpt =~ "not proof of cause"
    assert_received {:guard_ticket, ^guard_identity, 39_136_853_814, _}
    assert_received {:guard_ticket, ^guard_identity, 39_139_000_001, _}
    refute_received {:quarantine_pr, _, _}
  end

  test "a failing quarantine PR backs off, stops after seven attempts and raises one attention", %{journal: journal} do
    parent = self()
    t0 = System.system_time(:millisecond)

    opts =
      journal
      |> opts(parent)
      |> Keyword.merge(
        quarantine_pr_fun: fn _candidate, _ticket, _ ->
          send(parent, :attempt)
          {:error, :quarantine_auto_merge_unconfirmed}
        end,
        alert_emitter: fn topic, _ ->
          send(parent, {:alert, topic})
          :ok
        end
      )

    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]
    poll = fn offset_ms -> MergeGroupQuarantine.process_completed(runs, [], "main", Keyword.put(opts, :quarantine_now_ms, t0 + offset_ms)) end

    # Attempts at 0, then after 1, 2, 4, 8, 16 and 32 minutes; polls in between do nothing.
    schedule = Enum.scan([0, 1, 2, 4, 8, 16, 32], 0, &(&1 * 60_000 + &2))

    for {at, index} <- Enum.with_index(schedule) do
      if index > 0 do
        poll.(at - 1_000)
        refute_received :attempt
      end

      poll.(at)
      assert_received :attempt
    end

    assert_received {:alert, "system.pr.landing.quarantine_gave_up"}
    refute_received {:alert, _}

    poll.(List.last(schedule) + 120 * 60_000)
    refute_received :attempt
  end

  test "a failed requeue of the dropped PRs is retried after backoff without reopening the quarantine PR", %{journal: journal} do
    parent = self()
    {:ok, enqueues} = Agent.start_link(fn -> 0 end)

    pr = %{
      number: 4995,
      base: "main",
      head: "head-4995",
      node_id: "PR_4995",
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/4995-work"}}
    }

    opts =
      journal
      |> opts(parent)
      |> Keyword.merge(
        approved_fun: fn _, _ -> {:ok, true} end,
        revalidate_fun: fn _, _, _ -> :ok end,
        attribution_fun: fn _ -> {:ok, :clean} end,
        comment_fun: fn _, _, _ -> :ok end,
        enqueue_fun: fn node, _head, _ ->
          if Agent.get_and_update(enqueues, &{&1, &1 + 1}) == 0,
            do: {:error, "GitHub did not confirm enqueue"},
            else: send(parent, {:enqueue, node}) && {:ok, "entry"}
        end
      )

    runs = [group_run(39_136_853_814, "pr-4995-aaa", 30), group_run(39_139_000_001, "pr-5108-bbb", 10)]
    assert {:error, _} = MergeGroupQuarantine.process_completed(runs, [pr], "main", opts)
    assert_received {:quarantine_pr, 5200, _}
    refute_received {:enqueue, _}

    assert :ok = MergeGroupQuarantine.process_completed(runs, [pr], "main", Keyword.put(opts, :quarantine_now_ms, System.system_time(:millisecond) + 61_000))
    assert_received {:enqueue, "PR_4995"}
    refute_received {:quarantine_pr, _, _}
  end

  defp red_entry(minutes_ago) do
    test = %{identity: @reaper, path: @reaper_path, classification: :new_failure}

    %{
      sha: "1b6bdb9e3#{minutes_ago}",
      completed_at: minutes_ago_ms(minutes_ago),
      run_urls: [],
      digest: %FailureDigest{checks: [%{id: nil, name: "coverage (2/4)", url: @main_run, tests: [test]}], tests: [test]}
    }
  end

  # The main watcher keeps one entry per commit: a passing rerun replaces the failing one.
  defp rerun_green(minutes_ago), do: %{red_entry(minutes_ago) | digest: %FailureDigest{checks: [], tests: []}, completed_at: minutes_ago_ms(minutes_ago - 1)}

  defp green_entry(minutes_ago), do: %{sha: "green#{minutes_ago}", completed_at: minutes_ago_ms(minutes_ago), run_urls: [], digest: %FailureDigest{checks: [], tests: []}}

  defp opts(journal, parent) do
    [
      base_branch: "main",
      token: "test-gh-token",
      journal_path: journal,
      main_history_fun: fn -> [] end,
      request_fun: fn %{method: :get, url: url} ->
        cond do
          url =~ "/commits?" -> {:ok, %{status: 200, body: [%{"sha" => "fixsha"}]}}
          url =~ "/compare/" -> {:ok, %{status: 200, body: %{"status" => "behind"}}}
          true -> flunk("unexpected request #{url}")
        end
      end,
      changed_paths_fun: fn _pr, _opts -> {:ok, ["src/lib/aiur/unrelated.ex"]} end,
      commit_paths_fun: fn _sha, _opts -> {:ok, ["src/lib/aiur/unrelated.ex"]} end,
      jobs_fun: fn _run, _opts -> {:ok, [%{"id" => 117_701_756_559, "check_run_id" => 117_701_756_559, "name" => "coverage (2/4)", "conclusion" => "failure"}]} end,
      annotations_fun: fn _id, _opts -> {:ok, [%{"title" => "aiur-test-failure", "annotation_level" => "failure", "path" => @reaper_path, "message" => "new-failure :: " <> @reaper}]} end,
      flake_recorder: fn failure, run, [], recorder_opts ->
        send(parent, {:flake_ticket, "#{failure.module} :: #{failure.name}", run["id"]})
        recorder_opts[:issue_recorded_fun].(5200)
      end,
      quarantine_pr_fun: fn candidate, ticket, _opts ->
        send(parent, {:quarantine_pr, ticket, candidate})
        {:ok, %{"number" => 5201}}
      end
    ]
  end

  defp group_run(id, branch, minutes_ago) do
    %{
      "id" => id,
      "event" => "merge_group",
      "status" => "completed",
      "conclusion" => "failure",
      "head_sha" => "group-head-#{id}",
      "head_branch" => "gh-readonly-queue/main/#{branch}",
      "html_url" => "https://github.com/test-org/test-repo/actions/runs/#{id}",
      "created_at" => DateTime.utc_now() |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601()
    }
  end

  defp minutes_ago_ms(minutes), do: System.system_time(:millisecond) - minutes * 60_000
end
