defmodule Aiur.LandingWatch.MergeQueueWatchdogTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{Journal, MergeQueueWatchdog}

  defp observation(number, overrides \\ %{}) do
    Map.merge(
      %{
        number: number,
        head: head_ref(number),
        node_id: "PR_#{number}",
        draft?: false,
        review_decision: "APPROVED",
        auto_merge_request: nil,
        mergeable: "MERGEABLE",
        merge_state_status: "CLEAN",
        merge_queue_entry: %{"id" => "entry-#{number}", "state" => "UNMERGEABLE", "position" => 1}
      },
      Map.new(overrides)
    )
  end

  defp iso(milliseconds),
    do: DateTime.from_unix!(milliseconds, :millisecond) |> DateTime.to_iso8601()

  defp head_ref(number), do: String.pad_leading(Integer.to_string(number, 16), 40, "0")

  defp temp_journal do
    path =
      Path.join(
        System.tmp_dir!(),
        "merge-queue-watchdog-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end

  defp check_opts(parent, number, overrides \\ []) do
    head = head_ref(number)

    base_opts = [
      head_failure_fun: fn _, _ ->
        {:ok,
         %{
           classification: :inherited,
           failing_tests: ["test/aiur/example_test.exs:42"],
           rebuilt_groups: 6
         }}
      end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn ^number, ^head, _ ->
        send(parent, :revalidated)
        :ok
      end,
      request_fun: fn
        %{method: :post, body: %{"query" => query}} ->
          cond do
            query =~ "dequeuePullRequest" ->
              send(parent, :dequeued)
              {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}

            query =~ "enqueuePullRequest" ->
              {:ok,
               %{
                 status: 200,
                 body: %{
                   "data" => %{
                     "enqueuePullRequest" => %{
                       "mergeQueueEntry" => %{
                         "id" => "new",
                         "pullRequest" => %{
                           "id" => "PR_#{number}",
                           "headRefOid" => head_ref(number)
                         }
                       }
                     }
                   }
                 }
               }}
          end
      end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end
    ]

    Keyword.merge(base_opts, overrides)
  end

  test "waits twenty minutes, then repairs once and reports failing tests and rebuilt groups" do
    path = temp_journal()
    parent = self()
    observation = observation(47)
    opts = [journal_path: path, token: "test-gh-token"] ++ check_opts(parent, 47)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))
    refute_received :dequeued

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))
    refute_received :dequeued

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))

    assert_received :dequeued
    assert_received :revalidated

    assert_received {:attention, "system.pr.landing.merge_queue_recovered", attrs}
    assert attrs[:message] =~ "stayed UNMERGEABLE"
    assert attrs[:message] =~ "test/aiur/example_test.exs:42"
    assert String.contains?(attrs[:message], "Rebuilt groups behind this queue head: 6")

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 2_401_000))

    refute_received :dequeued
  end

  test "a queued interval restarts the twenty-minute UNMERGEABLE timer" do
    path = temp_journal()
    parent = self()
    unmergeable = observation(55)
    queued = observation(55, merge_queue_entry: %{"id" => "entry-55", "state" => "QUEUED"})
    opts = [journal_path: path, token: "test-gh-token"] ++ check_opts(parent, 55)
    at = &Keyword.put(opts, :now_ms, &1)

    assert :ok = MergeQueueWatchdog.reconcile([unmergeable], at.(1_000))
    assert :ok = MergeQueueWatchdog.reconcile([queued], at.(1_501_000))
    assert :ok = MergeQueueWatchdog.reconcile([unmergeable], at.(1_502_000))
    refute_received :dequeued

    assert :ok = MergeQueueWatchdog.reconcile([unmergeable], at.(2_701_000))
    refute_received :dequeued

    assert :ok = MergeQueueWatchdog.reconcile([unmergeable], at.(2_702_000))
    assert_received :dequeued
  end

  test "does not requeue a failure selected by the PR diff" do
    path = temp_journal()
    observation = observation(48)
    parent = self()
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    first_seen = now - 21 * 60_000
    failure_path = "src/test/aiur/changed_test.exs"

    run = %{
      "id" => 904,
      "event" => "merge_group",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/pr-48-#{head_ref(48)}",
      "created_at" => DateTime.from_unix!(now - 10 * 60_000, :millisecond) |> DateTime.to_iso8601()
    }

    opts = [
      journal_path: path,
      completed_merge_group_runs: [run],
      base_branch: "main",
      jobs_fun: fn 904, _ ->
        send(parent, :selected_run_jobs_read)
        {:ok, [%{"id" => 905, "name" => "tests", "conclusion" => "failure"}]}
      end,
      recent_main_failure_paths: [failure_path],
      known_failure_patterns: ["known flaky failure"],
      job_log_fun: fn _, _ ->
        {:ok, "1) test changed (Aiur.ChangedTest)\n   #{failure_path}:9"}
      end,
      changed_paths_fun: fn _, _ -> {:ok, [failure_path]} end,
      request_fun: fn _ -> flunk("a PR-caused failure must not be dequeued or enqueued") end
    ]

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, first_seen))

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [observation],
               Keyword.put(opts, :now_ms, first_seen + 20 * 60_000 + 1)
             )

    refute_received :dequeued
    assert_received :selected_run_jobs_read

    assert {:ok, state} = Journal.state(journal_path: path)

    assert get_in(state, [
             "unmergeable_queue_entries",
             "48:#{head_ref(48)}",
             "classified_merge_group_runs",
             "904",
             "reason"
           ]) ==
             "pr_caused_merge_group_failure"

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [observation],
               Keyword.put(opts, :now_ms, first_seen + 21 * 60_000)
             )

    refute_received :selected_run_jobs_read
  end

  test "does not consume the repair attempt when revalidation fails" do
    path = temp_journal()
    parent = self()
    observation = observation(49)
    attempts = Agent.start_link(fn -> 0 end) |> elem(1)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 49,
          revalidate_queue_fun: fn _, _ ->
            count = Agent.get_and_update(attempts, &{&1, &1 + 1})
            if count == 0, do: {:error, :transient_read_failure}, else: :ok
          end
        )

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    assert {:error, :transient_read_failure} =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_202_000))

    assert_received :dequeued
  end

  test "only one poll can reserve a queue recovery at a time" do
    path = temp_journal()
    parent = self()
    observation = observation(49)
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 49,
          revalidate_queue_fun: fn _, _ ->
            call = Agent.get_and_update(calls, &{&1, &1 + 1})

            if call == 0 do
              send(parent, :first_repair_reserved)
              receive do: (:continue_first_repair -> :ok)
            else
              send(parent, :second_repair_started)
              :ok
            end
          end
        )

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    first =
      Task.async(fn ->
        MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))
      end)

    assert_receive :first_repair_reserved, 2_000

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))

    refute_received :second_repair_started

    send(first.pid, :continue_first_repair)
    assert :ok = Task.await(first)
    assert_received :dequeued
    refute_received :dequeued
  end

  test "attempts recovery even when merge-group routing reports an error" do
    parent = self()
    observation = observation(50)

    assert {:error, :routing_failed} =
             MergeQueueWatchdog.after_reconcile(
               :ok,
               {:error, :routing_failed},
               [observation],
               merge_queue_watchdog_fun: fn [^observation], _opts ->
                 send(parent, :watchdog_ran)
                 :ok
               end
             )

    assert_received :watchdog_ran
  end

  test "uses merge-group failure evidence and counts runs for PRs behind the head" do
    path = temp_journal()
    parent = self()
    observation = observation(55)

    behind =
      observation(61,
        merge_queue_entry: %{"id" => "entry-61", "state" => "AWAITING_CHECKS", "position" => 2}
      )

    since_ms = DateTime.utc_now() |> DateTime.add(-25, :minute) |> DateTime.to_unix(:millisecond)

    failed_run = %{
      "id" => 900,
      "event" => "merge_group",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/pr-55-#{head_ref(55)}",
      "created_at" => iso(since_ms + 15 * 60_000)
    }

    earlier_group = %{
      "id" => 899,
      "event" => "merge_group",
      "head_branch" => "gh-readonly-queue/main/pr-61-next",
      "created_at" => iso(since_ms + 10 * 60_000)
    }

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 55,
          jobs_fun: fn 900, _ ->
            {:ok, [%{"id" => 901, "name" => "test", "conclusion" => "failure"}]}
          end,
          completed_merge_group_runs: [earlier_group, failed_run],
          all_observations: [observation, behind],
          base_branch: "main",
          recent_main_failure_paths: ["src/test/aiur/flaky_test.exs"],
          job_log_fun: fn _, _ ->
            {:ok, "1) test flaky (Aiur.FlakyTest)\n   src/test/aiur/flaky_test.exs:17"}
          end,
          changed_paths_fun: fn _, _ -> {:ok, []} end,
          known_failure_patterns: []
        )

    opts = Keyword.delete(opts, :head_failure_fun)
    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, since_ms))

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [observation],
               Keyword.put(opts, :now_ms, since_ms + 20 * 60_000)
             )

    assert_received :dequeued
    assert_received {:attention, "system.pr.landing.merge_queue_recovered", attrs}
    assert attrs[:message] =~ "test/aiur/flaky_test.exs"
    assert String.contains?(attrs[:message], "Rebuilt groups behind this queue head: 1")
  end

  test "ignores failed merge-group runs from before the current unmergeable period" do
    path = temp_journal()
    parent = self()
    observation = observation(56)
    since_ms = DateTime.utc_now() |> DateTime.add(-25, :minute) |> DateTime.to_unix(:millisecond)

    old_run = %{
      "id" => 910,
      "event" => "merge_group",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/pr-56-#{head_ref(56)}",
      "created_at" => iso(since_ms - 5 * 60_000)
    }

    opts = [
      journal_path: path,
      completed_merge_group_runs: [old_run],
      base_branch: "main",
      jobs_fun: fn 910, _ ->
        send(parent, :stale_jobs_read)
        {:ok, [%{"id" => 911, "name" => "tests", "conclusion" => "failure"}]}
      end,
      recent_main_failure_paths: ["src/test/aiur/flaky_test.exs"],
      job_log_fun: fn _, _ ->
        {:ok, "1) test flaky (Aiur.FlakyTest)\n   src/test/aiur/flaky_test.exs:10"}
      end,
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      known_failure_patterns: [],
      request_fun: fn _ -> flunk("stale evidence must not authorize recovery") end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, since_ms))

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [observation],
               Keyword.put(opts, :now_ms, since_ms + 20 * 60_000 + 1)
             )

    refute_received :dequeued
    refute_received :stale_jobs_read
  end

  test "does not dequeue if the fresh queue read shows the entry became mergeable" do
    path = temp_journal()
    parent = self()
    observation = observation(50)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 50, revalidate_queue_fun: fn _, _ -> {:skip, :queue_recovery_precondition_changed} end)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))

    refute_received :dequeued
  end

  test "does not dequeue when the real fresh read shows the entry became mergeable" do
    path = temp_journal()
    parent = self()
    observation = observation(54)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 54,
          request_fun: fn
            %{method: :post, body: %{"query" => query}} = call ->
              cond do
                query =~ "mergeQueueEntry{id state}" ->
                  send(parent, :fresh_queue_read)

                  {:ok,
                   %{
                     status: 200,
                     body: %{
                       "data" => %{
                         "repository" => %{
                           "pullRequest" => %{
                             "id" => "PR_54",
                             "headRefOid" => "head-54",
                             "isDraft" => false,
                             "reviewDecision" => "APPROVED",
                             "mergeable" => "MERGEABLE",
                             "mergeStateStatus" => "CLEAN",
                             "autoMergeRequest" => nil,
                             "mergeQueueEntry" => %{"id" => "entry-54", "state" => "MERGEABLE"},
                             "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-54"}}]}
                           }
                         }
                       }
                     }
                   }}

                query =~ "dequeuePullRequest" ->
                  flunk("a changed queue entry must prevent dequeue")

                true ->
                  flunk("unexpected GraphQL request: #{inspect(call)}")
              end
          end
        )

    opts =
      opts
      |> Keyword.delete(:revalidate_queue_fun)
      |> Keyword.delete(:queue_recovery_revalidate_fun)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    assert :ok =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))

    assert_received :fresh_queue_read
    refute_received :dequeued
  end
end
