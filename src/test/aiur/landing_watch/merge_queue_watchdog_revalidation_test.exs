defmodule Aiur.LandingWatch.MergeQueueWatchdogRevalidationTest do
  use ExUnit.Case, async: true

  alias Aiur.LandingWatch.MergeQueueWatchdog

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

  defp head_ref(number), do: String.pad_leading(Integer.to_string(number, 16), 40, "0")

  defp temp_journal do
    path = Path.join(System.tmp_dir!(), "merge-queue-watchdog-review-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end

  defp check_opts(parent, number, overrides \\ []) do
    head = head_ref(number)

    base_opts = [
      head_failure_fun: fn _, _ -> {:ok, %{classification: :inherited, failing_tests: [], rebuilt_groups: 0}} end,
      revalidate_queue_fun: fn _, _ -> :ok end,
      queue_recovery_revalidate_fun: fn ^number, ^head, _ ->
        send(parent, :revalidated)
        :ok
      end,
      request_fun: fn %{method: :post, body: %{"query" => query}} ->
        cond do
          query =~ "dequeuePullRequest" ->
            send(parent, :dequeued)
            {:ok, %{status: 200, body: %{"data" => %{"dequeuePullRequest" => %{}}}}}

          query =~ "enqueuePullRequest" ->
            {:ok, %{status: 200, body: %{"data" => %{"enqueuePullRequest" => %{"mergeQueueEntry" => %{"id" => "new", "pullRequest" => %{"id" => "PR_#{number}", "headRefOid" => head}}}}}}}
        end
      end,
      alert_emitter: fn topic, attrs ->
        send(parent, {:attention, topic, attrs})
        :ok
      end
    ]

    Keyword.merge(base_opts, overrides)
  end

  test "malformed post-dequeue PR revalidation still re-enqueues and raises attention" do
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

                Map.get(call, :method) == :post and query =~ "enqueuePullRequest" ->
                  send(parent, :enqueued_after_malformed_revalidation)

                  {:ok,
                   %{
                     status: 200,
                     body: %{
                       "data" => %{
                         "enqueuePullRequest" => %{
                           "mergeQueueEntry" => %{
                             "id" => "new-entry",
                             "pullRequest" => %{"id" => "PR_53", "headRefOid" => observation.head}
                           }
                         }
                       }
                     }
                   }}
              end
          end
        )

    opts = Keyword.delete(opts, :queue_recovery_revalidate_fun)

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_000))

    assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, 1_201_000))
    assert_received :enqueued_after_malformed_revalidation

    assert_received {:attention, "system.pr.landing.merge_queue_recovery_revalidation_changed", attrs}

    assert attrs[:message] =~ "PR #53"
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
                 Keyword.put(opts, :now_ms, 1_201_000)
               )

      refute_received :dequeued
      refute_received :revalidated
    end
  end

  test "stops after one repair attempt and emits one give-up attention" do
    path = temp_journal()
    parent = self()
    observation = observation(52)
    opts = [journal_path: path, token: "test-gh-token"] ++ check_opts(parent, 52)

    for now <- [1_000, 1_201_000, 2_401_000, 3_601_000] do
      assert :ok = MergeQueueWatchdog.reconcile([observation], Keyword.put(opts, :now_ms, now))
    end

    assert_received :dequeued
    refute_received :dequeued
    assert_received {:attention, "system.pr.landing.merge_queue_recovered", _}
    refute_received {:attention, "system.pr.landing.merge_queue_recovered", _}

    assert_received {:attention, "system.pr.landing.merge_queue_recovery_gave_up", attrs}
    assert attrs[:reason] == "merge_queue_recovery_attempt_limit"

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
