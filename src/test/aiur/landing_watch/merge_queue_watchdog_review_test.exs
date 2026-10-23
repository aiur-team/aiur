defmodule Aiur.LandingWatch.MergeQueueWatchdogReviewTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.{
    Journal,
    LandingReconciliation,
    MergeGroupFailureProcessor,
    MergeQueueFailureEvidence,
    MergeQueueWatchdog
  }

  test "landing reconciliation passes prepared flake evidence to the watchdog" do
    parent = self()
    run = failed_run(790, iso(DateTime.utc_now() |> DateTime.to_unix(:millisecond)), 79)
    observation = observation(79, "UNMERGEABLE", "UNKNOWN")

    opts = [
      journal_path: temp_journal(),
      base_branch: "main",
      hold_rework: true,
      merge_group_runs: [run],
      jobs_fun: fn _, _ -> {:ok, []} end,
      changed_paths_fun: fn _, _ -> {:ok, []} end,
      recent_main_failure_paths_fun: fn _, _ -> {:ok, ["test/aiur/flaky_test.exs"]} end,
      known_failure_patterns_fun: fn ->
        {:ok, [%{"title" => "known flaky signature", "body" => "known flaky signature"}]}
      end,
      queue_reconcile_fun: fn observations, reconcile_opts ->
        reconcile_opts[:merge_group_evidence_fun].([run], observations, reconcile_opts)

        MergeGroupFailureProcessor.process_completed(
          [run],
          observations,
          "main",
          reconcile_opts
        )
      end,
      merge_queue_watchdog_fun: fn _, watchdog_opts ->
        send(
          parent,
          {:prepared_evidence, watchdog_opts[:recent_main_failure_paths], watchdog_opts[:known_failure_patterns]}
        )

        :ok
      end
    ]

    assert :ok = LandingReconciliation.process([observation], opts, fn _, _ -> :ok end)
    assert_received {:prepared_evidence, ["test/aiur/flaky_test.exs"], patterns}
    assert "known flaky signature" in patterns
  end

  test "starts the failure-count clock at the second failed group run in this PR head's queue window" do
    base = DateTime.utc_now() |> DateTime.add(-30, :minute)
    earlier = DateTime.to_iso8601(base)
    later = base |> DateTime.add(10, :minute) |> DateTime.to_iso8601()

    group_ahead = String.duplicate("a", 40)
    unrelated_group_ahead = String.duplicate("b", 40)
    runs = [failed_run(1, earlier, 48, group_ahead), failed_run(2, later, 48, group_ahead)]

    assert MergeQueueFailureEvidence.failed_group_trigger_since_ms(
             48,
             runs,
             "main",
             DateTime.from_iso8601(earlier) |> elem(1) |> DateTime.to_unix(:millisecond)
           ) ==
             base |> DateTime.add(10, :minute) |> DateTime.to_unix(:millisecond)

    assert MergeQueueFailureEvidence.failed_group_trigger_since_ms(
             48,
             [failed_run(1, earlier, 49, group_ahead), failed_run(2, later, 49, group_ahead)],
             "main",
             0
           ) == nil

    assert MergeQueueFailureEvidence.failed_group_trigger_since_ms(
             48,
             runs,
             "main",
             DateTime.from_iso8601(later) |> elem(1) |> DateTime.to_unix(:millisecond)
           ) == nil

    assert MergeQueueFailureEvidence.failed_group_trigger_since_ms(
             48,
             [failed_run(1, earlier, 48, group_ahead), failed_run(2, later, 48, unrelated_group_ahead)],
             "main",
             DateTime.from_iso8601(earlier) |> elem(1) |> DateTime.to_unix(:millisecond)
           ) == base |> DateTime.add(10, :minute) |> DateTime.to_unix(:millisecond)
  end

  test "keeps the watchdog timer through AWAITING_CHECKS and repairs when the head is unmergeable again" do
    path = temp_journal()
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    started = now - 25 * 60_000
    parent = self()

    waiting = observation(80, "AWAITING_CHECKS", "UNKNOWN")
    unmergeable = observation(80, "UNMERGEABLE", "UNKNOWN")
    runs = [failed_run(801, iso(started - 60_000), 80), failed_run(802, iso(started), 80)]

    opts = [
      journal_path: path,
      token: "test-gh-token",
      now_ms: now,
      base_branch: "main",
      completed_merge_group_runs: runs,
      head_failure_fun: fn _, _ ->
        {:ok, %{classification: :inherited, failing_tests: [], rebuilt_groups: 0}}
      end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn _, _, _ -> :ok end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end,
      request_fun: fn %{body: %{"query" => query}} ->
        cond do
          query =~ "dequeuePullRequest" ->
            send(parent, :dequeued_after_recovery)
            {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}

          query =~ "enqueuePullRequest" ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "enqueuePullRequest" => %{
                     "mergeQueueEntry" => %{
                       "id" => "new-entry",
                       "pullRequest" => %{"id" => "PR_80", "headRefOid" => head_ref(80)}
                     }
                   }
                 }
               }
             }}
        end
      end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([waiting], Keyword.put(opts, :now_ms, started - 30 * 60_000))
    assert :ok = MergeQueueWatchdog.reconcile([waiting], opts)
    assert {:ok, waiting_state} = Journal.state(journal_path: path)

    assert get_in(waiting_state, ["unmergeable_queue_entries", "80:#{head_ref(80)}", "since"]) ==
             started - 30 * 60_000

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [unmergeable],
               Keyword.put(opts, :completed_merge_group_runs, [])
             )

    assert_received :dequeued_after_recovery
    assert {:ok, state} = Journal.state(journal_path: path)
    assert get_in(state, ["unmergeable_queue_entries", "80:#{head_ref(80)}", "attempts"]) == 1
  end

  test "keeps first-seen time through queued states and resets it when the PR head changes" do
    path = temp_journal()
    first_seen = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    parent_head = head_ref(85)
    new_head = head_ref(86)
    observation = observation(85, "UNMERGEABLE", "UNKNOWN")
    queued = %{observation | merge_queue_entry: %{"id" => "entry-85", "state" => "QUEUED"}}

    opts = [journal_path: path, base_branch: "main", now_ms: first_seen]

    assert :ok = MergeQueueWatchdog.reconcile([observation], opts)
    assert :ok = MergeQueueWatchdog.reconcile([queued], Keyword.put(opts, :now_ms, first_seen + 60_000))

    assert {:ok, queued_state} = Journal.state(journal_path: path)

    assert get_in(queued_state, ["unmergeable_queue_entries", "85:#{parent_head}", "first_seen_ms"]) ==
             first_seen

    changed_head = %{queued | head: new_head}

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [changed_head],
               Keyword.put(opts, :now_ms, first_seen + 120_000)
             )

    assert {:ok, changed_state} = Journal.state(journal_path: path)
    refute get_in(changed_state, ["unmergeable_queue_entries", "85:#{parent_head}"])

    assert get_in(changed_state, ["unmergeable_queue_entries", "85:#{new_head}", "first_seen_ms"]) ==
             first_seen + 120_000

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [%{number: 85, head: new_head}],
               Keyword.put(opts, :now_ms, first_seen + 180_000)
             )

    assert {:ok, left_queue_state} = Journal.state(journal_path: path)

    assert get_in(left_queue_state, ["unmergeable_queue_entries", "85:#{new_head}", "first_seen_ms"]) ==
             nil
  end

  test "commits the recovery attempt immediately after dequeue even when enqueue fails" do
    path = temp_journal()
    parent = self()
    observation = observation(81, "UNMERGEABLE", "UNKNOWN")
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    since = now - 21 * 60_000

    opts = [
      journal_path: path,
      token: "test-gh-token",
      now_ms: now,
      base_branch: "main",
      completed_merge_group_runs: [
        failed_run(811, iso(since - 1_000), 81),
        failed_run(812, iso(since), 81)
      ],
      head_failure_fun: fn _, _ ->
        {:ok, %{classification: :inherited, failing_tests: [], rebuilt_groups: 0}}
      end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn _, _, _ -> :ok end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end,
      request_fun: fn %{body: %{"query" => query}} ->
        cond do
          query =~ "dequeuePullRequest" ->
            send(parent, :dequeued_before_enqueue_failure)
            {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}

          query =~ "enqueuePullRequest" ->
            {:error, :enqueue_failed}
        end
      end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, since - 5_000))

    assert {:error, {:github, :transport, %{reason: :enqueue_failed}}} =
             MergeQueueWatchdog.reconcile([observation], opts)

    assert_received :dequeued_before_enqueue_failure
    assert {:ok, state} = Journal.state(journal_path: path)
    row = get_in(state, ["unmergeable_queue_entries", "81:#{head_ref(81)}"])
    assert row["attempts"] == 1
    refute Map.has_key?(row, "recovery_pending")
    assert_received {:attention, "system.pr.landing.merge_queue_recovery_enqueue_failed", attrs}
    assert attrs[:message] =~ "PR #81"
  end

  test "does not recover when failure evidence cannot be fetched" do
    path = temp_journal()
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    since = now - 21 * 60_000
    runs = [failed_run(821, iso(since - 1_000), 82), failed_run(822, iso(since), 82)]
    observation = observation(82, "UNMERGEABLE", "UNKNOWN")

    opts = [
      journal_path: path,
      now_ms: now,
      base_branch: "main",
      completed_merge_group_runs: runs,
      jobs_fun: fn _, _ -> {:error, :evidence_unavailable} end,
      request_fun: fn _ -> flunk("unavailable evidence cannot authorize recovery") end
    ]

    assert :ok =
             MergeQueueWatchdog.reconcile(
               [observation],
               opts |> Keyword.put(:completed_merge_group_runs, []) |> Keyword.put(:now_ms, since)
             )

    assert {:ok, initial_state} = Journal.state(journal_path: path)

    assert get_in(initial_state, [
             "unmergeable_queue_entries",
             "82:#{head_ref(82)}",
             "first_seen_ms"
           ]) == since

    assert :ok = MergeQueueWatchdog.reconcile([observation], opts)
    assert {:ok, state} = Journal.state(journal_path: path)

    verdict =
      get_in(state, [
        "unmergeable_queue_entries",
        "82:#{head_ref(82)}",
        "classified_merge_group_runs",
        "822"
      ])

    assert is_nil(verdict)
  end

  test "still re-enqueues after the attempt journal commit fails" do
    path = temp_journal()
    parent = self()
    observation = observation(83, "UNMERGEABLE", "UNKNOWN")
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    since = now - 21 * 60_000

    opts = [
      journal_path: path,
      token: "test-gh-token",
      now_ms: now,
      base_branch: "main",
      completed_merge_group_runs: [failed_run(831, iso(since - 1_000), 83), failed_run(832, iso(since), 83)],
      head_failure_fun: fn _, _ -> {:ok, %{classification: :inherited, failing_tests: [], rebuilt_groups: 0}} end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn _, _, _ -> :ok end,
      recovery_attempt_commit_fun: fn _, _, _ -> {:error, :journal_write_failed} end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end,
      request_fun: fn %{body: %{"query" => query}} ->
        if query =~ "enqueuePullRequest" do
          send(parent, :enqueued_after_commit_failure)
          {:ok, %{status: 200, body: %{"data" => %{"enqueuePullRequest" => %{"mergeQueueEntry" => %{"id" => "new", "pullRequest" => %{"id" => "PR_83", "headRefOid" => head_ref(83)}}}}}}}
        else
          {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}
        end
      end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, since - 5_000))
    assert :ok = MergeQueueWatchdog.reconcile([observation], opts)
    assert_received :enqueued_after_commit_failure
    assert_received {:attention, "system.pr.landing.merge_queue_recovery_attempt_commit_failed", attrs}
    message = Keyword.fetch!(attrs, :message)
    assert message =~ "PR #83"
  end

  test "re-enqueues and alerts when post-dequeue eligibility revalidation fails" do
    path = temp_journal()
    parent = self()
    observation = observation(84, "UNMERGEABLE", "UNKNOWN")
    now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    since = now - 21 * 60_000

    opts = [
      journal_path: path,
      token: "test-gh-token",
      now_ms: now,
      base_branch: "main",
      completed_merge_group_runs: [failed_run(841, iso(since - 1_000), 84), failed_run(842, iso(since), 84)],
      head_failure_fun: fn _, _ -> {:ok, %{classification: :inherited, failing_tests: [], rebuilt_groups: 0}} end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn _, _, _ -> {:error, :read_failed} end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end,
      request_fun: fn %{body: %{"query" => query}} ->
        cond do
          query =~ "dequeuePullRequest" ->
            send(parent, :dequeued_before_revalidation_failure)
            {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}

          query =~ "enqueuePullRequest" ->
            send(parent, :enqueued_after_revalidation_failure)

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "enqueuePullRequest" => %{
                     "mergeQueueEntry" => %{
                       "id" => "new-entry",
                       "pullRequest" => %{"id" => "PR_84", "headRefOid" => head_ref(84)}
                     }
                   }
                 }
               }
             }}
        end
      end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, since - 5_000))
    assert :ok = MergeQueueWatchdog.reconcile([observation], opts)
    assert_received :dequeued_before_revalidation_failure
    assert_received :enqueued_after_revalidation_failure
    assert_received {:attention, "system.pr.landing.merge_queue_recovery_revalidation_changed", attrs}
    assert attrs[:message] =~ "PR #84"
  end

  defp observation(number, state, mergeable) do
    %{
      number: number,
      head: head_ref(number),
      node_id: "PR_#{number}",
      draft?: false,
      review_decision: "APPROVED",
      auto_merge_request: nil,
      mergeable: mergeable,
      merge_state_status: "UNKNOWN",
      merge_queue_entry: %{"id" => "entry-#{number}", "state" => state, "position" => 1}
    }
  end

  defp failed_run(id, created_at, number, head \\ nil) do
    %{
      "id" => id,
      "event" => "merge_group",
      "conclusion" => "failure",
      "head_branch" => "gh-readonly-queue/main/pr-#{number}-#{head || head_ref(number)}",
      "created_at" => created_at
    }
  end

  defp head_ref(number), do: String.pad_leading(Integer.to_string(number, 16), 40, "0")

  defp iso(milliseconds),
    do: DateTime.from_unix!(milliseconds, :millisecond) |> DateTime.to_iso8601()

  defp temp_journal do
    path =
      Path.join(
        System.tmp_dir!(),
        "merge-queue-watchdog-review-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
