defmodule Aiur.Orchestrator.CiLifecycle.PollTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.CiLifecycleTestSupport.SlowTransitionClient
  alias Aiur.Events.Publisher
  alias Aiur.ExecutorListener
  alias Aiur.ExecutorWakeInbox
  alias Aiur.GitHub.ResourceStore
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.DispatchPolicy
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.State
  alias Aiur.Orchestrator.TrackerTasks
  alias Aiur.PollCadence
  alias Aiur.TestSupport.WakeInboxAck

  setup :ci_lifecycle_setup

  describe "CI lifecycle coordination" do
    test "only broker timeouts bypass CI cadence after a failed target lookup" do
      PollCadence.forget_effective_interval_ms()
      PollCadence.publish_effective_interval_ms(120_000, class: :ci)
      on_exit(&PollCadence.forget_effective_interval_ms/0)
      ticket = issue(unique_identifier("ci-broker-retry"), "ci-wait")

      failures = [
        {:github, :local_hold, %{reason: :github_budget_broker_timeout}},
        {:aiur, :locally_held, %{reason: :shared_budget}},
        {:github, :http, %{status: 500}}
      ]

      for failure <- failures do
        calls = :ets.new(:ci_broker_retry_calls, [:set, :public])
        :ets.insert(calls, {:count, 0})

        opts = [
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [ticket]} end,
          ci_poller: fn _targets, _opts ->
            :ets.update_counter(calls, :count, 1)
            {:ok, %{results: [], errors: [{ticket.identifier, {:pr_lookup, failure}}]}}
          end,
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        ]

        failed = CiLifecycle.poll_github_ci(%State{}, opts)

        if failure == hd(failures) do
          assert failed.last_ci_poll_started_at_ms == nil
          retried = CiLifecycle.poll_github_ci(failed, opts)
          assert :ets.lookup_element(calls, :count, 2) == 2
          assert is_integer(retried.last_ci_poll_started_at_ms)
          assert retried.ci_lifecycle.broker_fast_retry_pending? == false
          _cadence_limited = CiLifecycle.poll_github_ci(retried, opts)
          assert :ets.lookup_element(calls, :count, 2) == 2
        else
          assert is_integer(failed.last_ci_poll_started_at_ms)
          _still_on_cadence = CiLifecycle.poll_github_ci(failed, opts)
          assert :ets.lookup_element(calls, :count, 2) == 1
        end

        :ets.delete(calls)
      end
    end

    test "CI poll fetch runs outside the owner and late results preserve current state" do
      recipient = self()
      ticket = issue(unique_identifier("async-ci"), "human-review")
      state = running_state(ticket, self(), :paused, paused_reason: :ci_wait)

      continuation = fn current ->
        send(recipient, :ci_poll_continued)
        current
      end

      next =
        CiLifecycle.start_poll(state, continuation,
          ci_issue_fetcher: fn _states ->
            send(recipient, {:ci_fetch_started, self()})

            receive do
              :finish_ci_fetch -> {:ok, [ticket]}
            end
          end,
          ci_poller: fn _targets, _opts ->
            {:ok, %{results: [%{target: ticket.identifier, decision: :pending, head_sha: "new-head"}], errors: []}}
          end,
          alert_loader: fn -> [] end
        )

      receive_barrier({:ci_fetch_started, worker})
      assert worker != self()
      ref = next.tracker_tasks |> Map.keys() |> hd()
      current = %{next | running: %{}, claimed: MapSet.new(["concurrent-claim"]), ci_lifecycle: %{next.ci_lifecycle | approved_heads: %{"concurrent-ticket" => "concurrent-head"}}}
      send(worker, :finish_ci_fetch)
      receive_barrier({^ref, result})
      assert {:handled, applied} = TrackerTasks.result(current, ref, result)
      receive_barrier(:ci_poll_continued)
      assert applied.running == %{}
      assert applied.claimed == MapSet.new(["concurrent-claim"])
      assert applied.ci_lifecycle.approved_heads["concurrent-ticket"] == "concurrent-head"
      assert applied.tracker_tasks == %{}
      refute Map.has_key?(Map.get(applied.ci_lifecycle, :last_results, %{}), ticket.identifier)
    end

    test "CI transition writes run outside owner and cannot restore an exited runner" do
      Application.put_env(:aiur, :github_client_module, SlowTransitionClient)
      Application.put_env(:aiur, :ci_slow_transition_recipient, self())
      on_exit(fn -> Application.delete_env(:aiur, :ci_slow_transition_recipient) end)
      name = {__MODULE__, make_ref()}
      :yes = :global.register_name(name, self())
      on_exit(fn -> :global.unregister_name(name) end)
      ticket = issue(unique_identifier("async-ci-write"), "human-review")
      state = %{running_state(ticket, self(), :paused, paused_reason: :ci_wait) | snapshot_key: {:global, name}}

      next = CiLifecycle.transition_ci_ticket(state, ticket, "ci-wait")
      receive_barrier({:ci_transition_started, worker, issue_id, "ci-wait", opts})
      assert worker != self()
      assert issue_id == ticket.id
      assert opts == [expected_state: "human-review"]
      ref = next.tracker_tasks |> Map.keys() |> hd()
      send(worker, :finish_ci_transition)
      receive_barrier({^ref, result})
      assert {:handled, applied} = TrackerTasks.result(%{next | running: %{}}, ref, result)
      assert applied.running == %{}
      assert applied.tracker_tasks == %{}
    end

    test "observes human-review handoffs outside active states and records one Executor wake" do
      Publisher.set_tracked_fn(fn _ -> true end)
      on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)

      previous = issue(unique_identifier("human-review-handoff"), "rework")
      start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
      start_supervised!({ExecutorListener, name: Aiur.ExecutorListener.CIHandoffTest, patterns: ["ticket.#{previous.identifier}.agent.handoff.human_review"]})
      current = %{previous | state: "human-review"}
      sha = String.duplicate("e", 40)
      key = ResourceStore.key_for_repo(:branch_pull_request_listing, "its-everdred/aiur", previous.id)
      :ok = ResourceStore.put_resource(key, %{"number" => 3022, "head" => %{"sha" => sha}})
      parent = self()

      opts = [
        ci_issue_fetcher: fn ["ci-wait", "human-review"] ->
          send(parent, :ci_issue_fetch)
          {:ok, [current]}
        end,
        ci_poller: fn _targets, _opts -> {:ok, %{results: [], errors: []}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end
      ]

      state = %State{
        last_polled_issues: %{previous.id => previous},
        human_review_observed_ids: MapSet.new()
      }

      candidate_poll =
        IssueSync.sync_polled_issue_state(
          state,
          [],
          fn _ids -> {:ok, [current]} end,
          fn _identity, _lifecycle -> :ok end,
          MapSet.new(["done"]),
          fn _ -> :ok end,
          fn _identity, _pending? -> :ok end
        )

      assert candidate_poll.last_polled_issues == %{}

      first = CiLifecycle.poll_github_ci(candidate_poll, opts)
      assert_received :ci_issue_fetch
      assert MapSet.member?(first.human_review_observed_ids, current.id)

      assert {:ok, [wake]} = ExecutorWakeInbox.wait(500)
      assert wake["topic"] == "ticket.#{current.identifier}.agent.handoff.human_review"
      assert wake["pr_number"] == 3022
      assert wake["head_sha"] == sha
      assert first.last_polled_issues == %{}

      _second = CiLifecycle.poll_github_ci(%{first | last_ci_poll_started_at_ms: nil}, opts)
      assert_received :ci_issue_fetch
      _ = :sys.get_state(Aiur.ExecutorListener.CIHandoffTest)
      :ok = WakeInboxAck.ack_as_owner([wake])
      assert :timeout = ExecutorWakeInbox.wait(0)
    end

    test "seeds existing human-review issues on the first CI poll without waking" do
      Publisher.set_tracked_fn(fn _ -> true end)
      on_exit(fn -> Publisher.set_tracked_fn(fn _ -> true end) end)

      current = issue(unique_identifier("human-review-at-boot"), "human-review")
      start_supervised!({ExecutorWakeInbox, debounce_ms: 10})
      start_supervised!({ExecutorListener, name: Aiur.ExecutorListener.CIHandoffBootTest, patterns: ["ticket.#{current.identifier}.agent.handoff.human_review"]})

      opts = [
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [current]} end,
        ci_poller: fn _targets, _opts -> {:ok, %{results: [], errors: []}} end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end
      ]

      first = CiLifecycle.poll_github_ci(%State{}, opts)
      assert MapSet.member?(first.human_review_observed_ids, current.id)
      assert ExecutorWakeInbox.wait(50) == :timeout
    end

    test "draft fast gate never promotes ci-wait; ready full checks do" do
      identifier = unique_identifier("draft-fast-gate")
      RecordingGitHubClient.record_to(self())
      ticket = issue(identifier, "ci-wait")
      required = [%{name: "lint", app_id: nil}, %{name: "test", app_id: nil}]
      check = %{"name" => "lint", "status" => "completed", "conclusion" => "success"}
      pr = %{"number" => 71, "head" => %{"sha" => "head-71"}, "base" => %{"ref" => "main"}, "draft" => true}

      opts = [
        ci_issue_fetcher: fn _ -> {:ok, [ticket]} end,
        required_check_fetcher: fn _ -> {:ok, required} end,
        draft_stall_alert_loader: fn -> MapSet.new() end,
        parked_ready_alert_loader: fn -> MapSet.new() end
      ]

      batch = %{identifier => %{pull_request: pr, check_runs: [check], commit_status: %{"statuses" => []}}}
      next = CiLifecycle.poll_github_ci(%State{}, Keyword.put(opts, :ci_batch_fetcher, fn _, _ -> {:ok, batch} end))
      refute_received {:tracker_update, ^identifier, _, _}
      assert next.ci_lifecycle.approved_heads == %{}

      batch = put_in(batch, [identifier, :pull_request, "draft"], false)
      next = CiLifecycle.poll_github_ci(%{next | last_ci_poll_started_at_ms: nil}, Keyword.put(opts, :ci_batch_fetcher, fn _, _ -> {:ok, batch} end))
      refute_received {:tracker_update, ^identifier, _, _}
      assert next.ci_lifecycle.approved_heads == %{}

      batch = put_in(batch, [identifier, :check_runs], [check, %{check | "name" => "test"}])
      next = CiLifecycle.poll_github_ci(%{next | last_ci_poll_started_at_ms: nil}, Keyword.put(opts, :ci_batch_fetcher, fn _, _ -> {:ok, batch} end))
      assert_received {:tracker_update, ^identifier, "in-progress", _}
      assert next.ci_lifecycle.approved_heads[identifier] == "head-71"
    end

    test "a same-head approved PR dropped from the merge queue transitions to dispatchable rework" do
      identifier = unique_identifier("merge-queue-drop")
      RecordingGitHubClient.record_to(self())
      ticket = issue(identifier, "ci-wait")

      base = %State{}

      state = %{
        base
        | ci_lifecycle: %{
            base.ci_lifecycle
            | poll_cache: %{
                identifier => %{
                  decision: :pending,
                  head_sha: "same-head",
                  review_decision: "APPROVED",
                  merge_queue_entry: %{"id" => "queue-entry", "state" => "AWAITING_CHECKS"}
                }
              }
          }
      }

      next =
        CiLifecycle.poll_github_ci(state,
          ci_recovery_enabled: false,
          ci_issue_fetcher: fn _ -> {:ok, [ticket]} end,
          ci_poller: fn _targets, _opts ->
            {:ok,
             %{
               results: [
                 %{
                   target: identifier,
                   decision: :passed,
                   head_sha: "same-head",
                   pr_number: 71,
                   review_decision: "APPROVED",
                   merge_queue_entry: nil
                 }
               ],
               errors: []
             }}
          end
        )

      assert_received {:tracker_update, ^identifier, "rework", _opts}
      assert next.running == %{}
      assert DispatchPolicy.should_dispatch_issue?(%{ticket | state: "rework"}, next)
    end

    test "a delivered (displaced) result is inert: no transition, no cache projection" do
      identifier = unique_identifier("ci-delivered-inert")
      issue = issue(identifier, "ci-wait")
      state = %State{}

      next = poll_ci(state, issue, %{delivered: true, head_sha: "head-77", pr_number: 77})

      # A target the batch displaced because a webhook delivery answered it
      # must not move state and must not cache a projection: the real verdict
      # comes from the next non-displaced read (R10 — a CI verdict is never
      # answered from a held body at any age).
      assert next.ci_lifecycle.poll_cache == %{}
      assert next.claimed == MapSet.new()
    end

    test "a locally held GraphQL batch skips the REST fallback cycle" do
      issue = issue(unique_identifier("locally-held-ci-batch"), "ci-wait")
      state = %State{}

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_batch_fetcher: fn [_target], _opts ->
            {:error, {:aiur, :locally_held, %{resource: "graphql", reset_at: DateTime.add(DateTime.utc_now(), 45, :second)}}}
          end,
          request_fun: fn _request -> flunk("local GraphQL hold must not fan out to REST") end,
          token: "test-gh-token",
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      assert next.ci_lifecycle.poll_cache == %{}
    end

    test "a genuine GraphQL batch failure retains the REST fallback cycle" do
      identifier = unique_identifier("failed-ci-batch")
      issue = issue(identifier, "ci-wait")
      parent = self()

      request_fun = fn %{url: url} ->
        send(parent, {:rest_request, url})

        cond do
          String.contains?(url, "/pulls?") ->
            {:ok,
             %{
               status: 200,
               body: [
                 %{
                   "number" => 71,
                   "head" => %{"ref" => "aiur/#{identifier}", "sha" => "current-sha"},
                   "base" => %{"ref" => "main"}
                 }
               ]
             }}

          String.contains?(url, "/check-runs?") ->
            {:ok,
             %{
               status: 200,
               body: %{"check_runs" => [%{"name" => "lint", "status" => "completed", "conclusion" => "success"}]}
             }}

          String.ends_with?(url, "/status") ->
            {:ok, %{status: 200, body: %{"state" => "pending", "total_count" => 0, "statuses" => []}}}
        end
      end

      next =
        CiLifecycle.poll_github_ci(%State{},
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, [issue]} end,
          ci_batch_fetcher: fn [_target], _opts -> {:error, {:github, :rate_limited, %{status: 429}}} end,
          request_fun: request_fun,
          required_check_fetcher: fn _ -> {:ok, []} end,
          token: "test-gh-token",
          parked_ready_alert_loader: fn -> MapSet.new() end,
          draft_stall_alert_loader: fn -> MapSet.new() end
        )

      assert_received {:rest_request, _url}
      assert Map.has_key?(next.ci_lifecycle.poll_cache, identifier)
    end

    test "CI pruning preserves tracker list caches shared with other poll phases" do
      state = %State{
        ci_lifecycle: %{
          %State{}.ci_lifecycle
          | poll_cache: %{
              "stale-target" => %{head_sha: "old"},
              issue_list_cache: %{pages: %{1 => %{etag: "ci-v1"}}},
              candidate_list_cache: %{pages: %{1 => %{etag: "candidates-v1"}}}
            }
        }
      }

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end
        )

      assert next.ci_lifecycle.poll_cache == %{
               issue_list_cache: %{pages: %{1 => %{etag: "ci-v1"}}},
               candidate_list_cache: %{pages: %{1 => %{etag: "candidates-v1"}}}
             }
    end

    test "a completed runner entering CI wait is parked without a cooperative pause" do
      identifier = unique_identifier("completed-ci-wait")
      recorder = start_recorder()
      issue = issue(identifier, "ci-wait")

      state = running_state(issue, recorder, :completed, [])
      ref = Process.monitor(recorder)
      next = CiLifecycle.pause_issue_for_ci_wait(state, issue)

      assert_receive {:DOWN, ^ref, :process, ^recorder, :killed}, 1000
      refute_received {:recorded, _sequence, {:pause_agent, _request_id}}

      entry = Map.fetch!(next.running, identifier)
      assert entry.control.status == :deactivated
      assert entry.paused_reason == :ci_wait
      assert entry.pid == nil
      assert entry.ref == nil
      assert entry.completed_provenance
      assert entry.completion_totals_recorded
      assert %{token: token, timer_ref: timer_ref} = next.ci_lifecycle.rewakes[identifier]
      assert is_reference(token)
      assert is_reference(timer_ref)
    end
  end

  describe "CI poll :ci-cadence throttle" do
    setup do
      PollCadence.forget_effective_interval_ms()
      on_exit(&PollCadence.forget_effective_interval_ms/0)
      :ok
    end

    # The throttle returns the state untouched — no issue fetch, no GraphQL
    # poll — so the injected fetchers/pollers must never fire. This is the
    # whole point: an expensive CI read must not run at the dispatch rate once
    # an operator gives `:ci` its own (wider) cadence.
    test "skips the poll while within the published ci cadence" do
      PollCadence.publish_effective_interval_ms(300_000, class: :ci)
      state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn _states -> flunk("throttled poll must not fetch issues") end,
          ci_poller: fn _targets, _opts -> flunk("throttled poll must not poll") end,
          token: "test-gh-token"
        )

      assert next == state
    end

    # A recent poll is never throttled before the dispatcher has published a
    # live `:ci` cadence (cold start, harnesses): the first read of a freshly
    # in-flight PR must not be held back by a cadence nobody has observed yet.
    test "a recent poll is not throttled before the ci cadence is published" do
      PollCadence.forget_effective_interval_ms()
      issue = issue(unique_identifier("ci-unthrottled"), "ci-wait")
      state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond)}

      next = poll_ci(state, issue, %{status: "pending", head_sha: "head-1", pr_number: 1})

      assert next.last_ci_poll_started_at_ms != nil
      assert is_map(next.ci_lifecycle.poll_cache)
    end

    # Mutant #1 (review #2309): the CI throttle timestamp must NOT advance when
    # there are no in-flight targets. The loop is demand-scoped — it only polls
    # pull requests with work in flight — so a no-target tick is the "there is
    # nothing to read yet" state, and advancing the timestamp there would hold a
    # PR that enters `ci-wait` between polls back for the previous poll's full
    # cadence. This drives the production path and fails if the timestamp is
    # hoisted out of the `targets == []` guard.
    test "the ci throttle timestamp does not advance when no targets are in flight" do
      PollCadence.publish_effective_interval_ms(300_000, class: :ci)

      # Last polled long enough ago that the class cadence has elapsed, so the
      # loop is due to run — and then finds nothing in flight.
      state = %State{last_ci_poll_started_at_ms: System.monotonic_time(:millisecond) - 600_000}

      next =
        CiLifecycle.poll_github_ci(state,
          ci_issue_fetcher: fn _states -> {:ok, []} end,
          ci_poller: fn _targets, _opts -> flunk("no in-flight targets: the CI poll must not run") end,
          token: "test-gh-token"
        )

      # The demand-scoping rule: no targets read, so the throttle clock stays put.
      assert next.last_ci_poll_started_at_ms == state.last_ci_poll_started_at_ms
    end
  end
end
