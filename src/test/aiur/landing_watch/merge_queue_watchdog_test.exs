defmodule Aiur.LandingWatch.MergeQueueWatchdogTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeQueueWatchdog

  defp observation(number, overrides \\ %{}) do
    Map.merge(
      %{
        number: number,
        head: "head-#{number}",
        node_id: "PR_#{number}",
        draft?: false,
        review_decision: "APPROVED",
        auto_merge_request: nil,
        mergeable: "MERGEABLE",
        merge_state_status: "CLEAN",
        merge_queue_entry: %{"id" => "entry-#{number}", "state" => "UNMERGEABLE"}
      },
      Map.new(overrides)
    )
  end

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
    head = "head-#{number}"

    base_opts = [
      required_checks_snapshot: {:ok, [%{name: "ci", app_id: nil}]},
      ci_status_fun: fn ^head, _ ->
        {:ok,
         %{
           check_runs: [%{"name" => "ci", "status" => "completed", "conclusion" => "success"}],
           commit_status: %{"state" => "pending", "total_count" => 0, "statuses" => []}
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
                           "headRefOid" => "head-#{number}"
                         }
                       }
                     }
                   }
                 }
               }}
          end
      end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs[:reason]})
        :ok
      end
    ]

    Keyword.merge(base_opts, overrides)
  end

  test "waits five minutes, then repairs using the required-check run despite pending combined status" do
    path = temp_journal()
    parent = self()
    observation = observation(47)
    opts = [journal_path: path, token: "test-gh-token"] ++ check_opts(parent, 47)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))
    refute_received :dequeued

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))
    assert_received :dequeued
    assert_received :revalidated

    assert_received {:attention, "system.pr.landing.merge_queue_recovered", "stale_unmergeable_entry"}
  end

  test "does not dequeue when the PR's own required check failed" do
    path = temp_journal()
    observation = observation(48)

    opts = [
      journal_path: path,
      required_checks_snapshot: {:ok, [%{name: "ci", app_id: nil}]},
      ci_status_fun: fn _, _ ->
        {:ok,
         %{
           check_runs: [%{"name" => "ci", "status" => "completed", "conclusion" => "failure"}],
           commit_status: %{"state" => "pending", "total_count" => 0, "statuses" => []}
         }}
      end,
      request_fun: fn _ -> flunk("failed required checks must prevent any queue mutation") end
    ]

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))
    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))
  end

  test "does not dequeue if the fresh queue read shows the entry became mergeable" do
    path = temp_journal()
    parent = self()
    observation = observation(50)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 50, revalidate_queue_fun: fn _, _ -> {:skip, :queue_recovery_precondition_changed} end)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))
    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))
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

    opts = opts |> Keyword.delete(:revalidate_queue_fun) |> Keyword.delete(:queue_recovery_revalidate_fun)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))
    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))

    assert_received :fresh_queue_read
    refute_received :dequeued
  end

  test "malformed live PR revalidation returns an error instead of crashing the poll" do
    path = temp_journal()
    parent = self()
    observation = observation(53)

    opts =
      [journal_path: path, token: "test-gh-token"] ++
        check_opts(parent, 53,
          request_fun: fn
            %{body: %{"query" => query}} = call ->
              cond do
                query =~ "mergeQueueEntry{id state}" ->
                  {:ok,
                   %{
                     status: 200,
                     body: %{
                       "data" => %{
                         "repository" => %{
                           "pullRequest" => %{
                             "id" => "PR_53",
                             "headRefOid" => "head-53",
                             "isDraft" => false,
                             "reviewDecision" => "APPROVED",
                             "mergeable" => "MERGEABLE",
                             "mergeStateStatus" => "CLEAN",
                             "autoMergeRequest" => nil,
                             "mergeQueueEntry" => %{"id" => "entry-53", "state" => "UNMERGEABLE"},
                             "reviews" => %{"nodes" => [%{"commit" => %{"oid" => "head-53"}}]}
                           }
                         }
                       }
                     }
                   }}

                query =~ "mergeQueueEntry{id}" ->
                  {:ok, %{status: 200, body: %{"data" => %{"repository" => %{}}}}}

                Map.get(call, :method) == :post and query =~ "dequeuePullRequest" ->
                  {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}
              end
          end
        )

    opts = Keyword.delete(opts, :queue_recovery_revalidate_fun)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    assert {:error, :invalid_queue_recovery_revalidation} =
             MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 301_000))
  end

  for state <- ["AWAITING_CHECKS", "MERGEABLE", "LOCKED"] do
    test "does not touch queue entries in #{state}" do
      path = temp_journal()
      parent = self()

      observation =
        observation(51, merge_queue_entry: %{"id" => "entry-51", "state" => unquote(state)})

      opts =
        [journal_path: path] ++
          check_opts(parent, 51, request_fun: fn _ -> flunk("#{unquote(state)} entries must not be mutated") end)

      assert :ok =
               MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

      assert :ok =
               MergeQueueWatchdog.reconcile(
                 [observation],
                 Keyword.put(opts, :now_ms, 301_000)
               )

      refute_received :dequeued
      refute_received :revalidated
    end
  end

  test "stops after two repair attempts and emits one give-up attention" do
    path = temp_journal()
    parent = self()
    observation = observation(52)
    opts = [journal_path: path, token: "test-gh-token"] ++ check_opts(parent, 52)

    for now <- [1_000, 301_000, 601_000, 901_000, 961_000] do
      assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, now))
    end

    assert_received :dequeued
    assert_received :dequeued
    refute_received :dequeued
    assert_received {:attention, "system.pr.landing.merge_queue_recovered", _}
    assert_received {:attention, "system.pr.landing.merge_queue_recovered", _}

    assert_received {:attention, "system.pr.landing.merge_queue_recovery_gave_up", "merge_queue_recovery_attempt_limit"}

    refute_received {:attention, "system.pr.landing.merge_queue_recovery_gave_up", _}
  end

  test "does not requeue a conflicting PR even after the watchdog interval" do
    observation = observation(49, mergeable: "CONFLICTING")
    path = temp_journal()

    assert :ok = MergeQueueWatchdog.reconcile([observation], journal_path: path, now_ms: 1_000)

    assert :ok =
             MergeQueueWatchdog.reconcile([observation],
               journal_path: path,
               now_ms: 301_000,
               request_fun: fn _ ->
                 flunk("conflicting PRs must never be dequeued or enqueued")
               end
             )
  end
end
