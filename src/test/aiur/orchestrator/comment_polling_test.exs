defmodule Aiur.Orchestrator.CommentPollingTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{CommentPolling, State}
  alias Aiur.PollCadence

  setup do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-gh-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent"
    )

    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)

    :ok
  end

  defp base_state do
    %State{
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      queue_store: nil,
      last_polled_issues: %{},
      todo_over_capacity_alert_active: false,
      agent_totals: nil,
      agent_rate_limits: nil,
      codex_totals: nil,
      codex_rate_limits: nil,
      poll_interval_ms: 60_000,
      max_concurrent_agents: nil,
      session_max_concurrent_agents: nil,
      effective_concurrent_agents: nil,
      load_envelope_state: %{last_decrease_ms: nil, cpu_snapshot: nil},
      next_poll_due_at_ms: nil,
      poll_check_in_progress: nil,
      tick_timer_ref: nil,
      tick_token: nil,
      initial_dispatch_cycle: false,
      events_etag: nil,
      events_last_id: nil,
      github_comments_since: %{},
      github_comment_issue_updated_at: %{},
      github_connectivity: %{},
      github_poll_delays: %{},
      github_command_scan_since: nil
    }
  end

  describe "poll_github_comments/2" do
    test "makes no GitHub call and returns state unchanged with empty target set" do
      state = base_state()
      # review_issue_fetcher returns empty list so no targets are built
      opts = [review_issue_fetcher: fn _states -> {:ok, []} end, watch_pull_request_fetcher: fn _label -> {:ok, []} end]
      result = CommentPolling.poll_github_comments(state, opts)

      # Nothing changes except the per-cycle conditional issue-list cache, which
      # target discovery writes back before it finds an empty target set.
      # Compared narrowly rather than blanking `ci_lifecycle` wholesale, so a
      # regression touching e.g. `approved_heads` still fails here.
      assert put_in(result.ci_lifecycle.poll_cache[:issue_list_cache], nil) ==
               put_in(state.ci_lifecycle.poll_cache[:issue_list_cache], nil)
    end
  end

  describe "start_async/2 review-cadence throttle" do
    setup do
      PollCadence.forget_effective_interval_ms()
      :ok
    end

    # The skip branch returns the state unchanged and spawns nothing, so this is
    # the one `start_async` path a unit test can exercise without the full
    # owned-poll handshake machinery. The "runs" side is covered by the shared
    # `PollCadence.within_class_cadence?/3` contract in
    # `Aiur.PerClassCadenceTest`.
    test "does not start a poll while within the published review cadence" do
      PollCadence.publish_effective_interval_ms(300_000, class: :review)
      state = %{base_state() | last_comment_poll_started_at_ms: System.monotonic_time(:millisecond)}

      result = CommentPolling.start_async(state)

      assert result.github_comment_poll == nil
      assert result.last_comment_poll_started_at_ms == state.last_comment_poll_started_at_ms
    end

    test "a recent start does not throttle before the review cadence is published" do
      PollCadence.forget_effective_interval_ms()
      state = %{base_state() | last_comment_poll_started_at_ms: System.monotonic_time(:millisecond)}

      result = CommentPolling.start_async(state)

      assert result.github_comment_poll != nil
      # Clean up the spawned owner/poll so nothing leaks past the test.
      terminate_spawned_poll(result.github_comment_poll)
    end

    defp terminate_spawned_poll(%{owner: owner}) when is_pid(owner), do: Process.exit(owner, :kill)
    defp terminate_spawned_poll(_poll), do: :ok
  end

  describe "poll_github_firehose/2" do
    test "preserves stored etag on :not_modified response" do
      state = %{base_state() | events_etag: "abc123"}
      parent = self()

      request_fun = fn request ->
        send(parent, {:firehose_request, request})
        {:ok, %{status: 304, headers: [{"ETag", "abc123"}, {"X-Poll-Interval", "60"}], body: ""}}
      end

      result = CommentPolling.poll_github_firehose(state, request_fun: request_fun)

      assert result.events_etag == "abc123"
      assert_receive {:firehose_request, %{etag: "abc123"}}
    end

    test "persistent merge-store failure retries finitely, degrades, alerts, and advances" do
      state = %{
        base_state()
        | events_etag: "previous-etag",
          events_last_id: "last-seen"
      }

      event = %{
        "id" => "new-merge",
        "type" => "PullRequestEvent",
        "created_at" => "2026-07-12T18:00:00Z",
        "repo" => %{"name" => "owner/repo"},
        "payload" => %{
          "action" => "closed",
          "pull_request" => %{
            "number" => 42,
            "title" => "Merged feature",
            "body" => "Durable outcome",
            "html_url" => "https://github.com/owner/repo/pull/42",
            "merged" => true,
            "merged_at" => "2026-07-12T18:00:00Z",
            "head" => %{"ref" => "aiur/983-history", "sha" => "head-42"}
          }
        }
      }

      request_fun = fn
        %{etag: "new-etag"} ->
          {:ok, %{status: 304, headers: [{"ETag", "new-etag"}], body: ""}}

        %{etag: "previous-etag"} ->
          {:ok, %{status: 200, headers: [{"ETag", "new-etag"}], body: [event, %{"id" => "last-seen"}]}}
      end

      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      parent = self()

      opts = [
        request_fun: request_fun,
        recent_merge_fun: fn _merge ->
          Agent.update(attempts, &(&1 + 1))
          {:error, {:store_unavailable, {:unavailable, :read_only}}}
        end,
        recent_merge_alert_fun: fn topic, message, alert_opts ->
          send(parent, {:persistence_alert, topic, message, alert_opts})
          :ok
        end,
        boot_time: ~U[2026-07-12 17:00:00Z] |> DateTime.to_unix(),
        run_id: "current-run"
      ]

      first = CommentPolling.poll_github_firehose(state, opts)
      second = CommentPolling.poll_github_firehose(first, opts)

      assert first.events_etag == "previous-etag"
      assert first.events_last_id == "last-seen"
      assert second.events_etag == "previous-etag"
      assert second.events_last_id == "last-seen"

      third = CommentPolling.poll_github_firehose(second, opts)

      assert third.events_etag == "new-etag"
      assert third.events_last_id == "new-merge"
      # A local persistence failure is not lost connectivity: the catch-all no
      # longer stamps it `:transport`, so it lands `:unclassified` and backs off
      # at the conservative base rather than on the network escalation curve
      # (#2429 F2). The persistence alert below is the intended operator signal.
      assert third.github_connectivity[:recent_merge_store] == {:unclassified, 3}
      assert third.github_poll_delays[:recent_merge_store] == 1_000
      assert Agent.get(attempts, & &1) == 3

      assert_receive {:persistence_alert, "recent_merge_store.persistence_failed", message, alert_opts}
      assert message =~ "read-only"
      assert alert_opts[:needs_attention]
      refute_receive {:persistence_alert, _, _, _}

      fourth = CommentPolling.poll_github_firehose(third, opts)

      assert fourth.events_etag == "new-etag"
      assert fourth.events_last_id == "new-merge"
      assert fourth.github_connectivity[:recent_merge_store] == {:unclassified, 3}
      assert Agent.get(attempts, & &1) == 3
      refute_receive {:persistence_alert, _, _, _}
    end
  end

  # #2601: target discovery and the `/reviews` read are wired together through
  # `review_submission_targets`, so the state a ticket sits in decides whether
  # its pull request's review submissions are read at all. A ticket parked in
  # `agent:rework` after finishing its rework turn is exactly where a second
  # `CHANGES_REQUESTED` review lands, and it used to be excluded.
  #
  # The assertion is the request itself rather than a published event: the
  # published-event half already has coverage in the poller suite, and reaching
  # `/pulls/178/reviews` is the precise thing the state filter suppressed.
  describe "review submission reads by ticket state" do
    test "reads PR review submissions for a ticket in agent:rework" do
      # PR #178 takes a body-only CHANGES_REQUESTED review, the agent reworks
      # to a newer head, and the reviewer submits again. Phase one already
      # worked; phase two is the regression — the ticket is now `agent:rework`
      # and its `/reviews` endpoint has to keep being read for the second
      # review to exist at all.
      #
      # `review_issue_fetcher` models the real tracker by returning only issues
      # whose state label is one of the states it was asked for. Without
      # `rework` in the query the ticket is never returned, so no target is
      # built and no `/reviews` request is made — which is exactly how this
      # fails when the fix is reverted.
      poll_reviews_for = fn issue_state, issue_updated_at ->
        parent = self()

        issue = %Aiur.Issue{
          id: "164",
          identifier: "164",
          state: issue_state,
          updated_at: issue_updated_at
        }

        batch = %{
          "164" => %{
            open_pull_request: %{"number" => 178, "review_decision" => "CHANGES_REQUESTED"},
            issue_comments: [],
            pr_issue_comments: [],
            review_thread_comments: []
          }
        }

        opts = [
          repo: "owner/repo",
          review_issue_fetcher: fn states -> {:ok, Enum.filter([issue], &(&1.state in states))} end,
          review_pull_request_fetcher: fn "164" -> {:ok, %{"number" => 178}} end,
          watch_pull_request_fetcher: fn _label -> {:ok, []} end,
          comment_batch_fetcher: fn _targets, _opts -> {:ok, batch} end,
          request_fun: fn %{url: url} ->
            send(parent, {:requested, url})
            {:ok, %{status: 200, body: []}}
          end
        ]

        state = %{base_state() | github_comments_since: %{"164" => "2026-09-10T00:00:00Z"}}

        assert is_struct(CommentPolling.poll_github_comments(state, opts), State)

        drain_requested_urls([])
      end

      first_head_urls = poll_reviews_for.("human-review", "2026-09-10T00:10:30Z")
      assert Enum.any?(first_head_urls, &(&1 =~ "/pulls/178/reviews"))

      second_head_urls = poll_reviews_for.("rework", "2026-09-10T00:46:36Z")

      assert Enum.any?(second_head_urls, &(&1 =~ "/pulls/178/reviews")),
             "a ticket in agent:rework must still have its PR review submissions read; " <>
               "requested instead: #{inspect(second_head_urls)}"
    end
  end

  # Requests are made concurrently, so the reviews read is not reliably the
  # first message in the mailbox. Collect them all, then assert over the set.
  defp drain_requested_urls(acc) do
    receive do
      {:requested, url} -> drain_requested_urls([url | acc])
    after
      200 -> acc
    end
  end

  describe "human_review_comment_target_limit behavior" do
    test "caps human-review targets at 25 with more idle review issues" do
      {:ok, probe} = Agent.start_link(fn -> 0 end)

      opts = [
        review_issue_fetcher: fn _states ->
          issues =
            for i <- 1..30 do
              %Aiur.Issue{
                id: "issue-#{i}",
                identifier: "ISSUE-#{i}",
                state: "human-review",
                updated_at: "2024-01-0#{rem(i, 9) + 1}T00:00:00Z"
              }
            end

          {:ok, issues}
        end,
        watch_pull_request_fetcher: fn _label -> {:ok, []} end,
        review_pull_request_fetcher: fn _target ->
          Agent.update(probe, &(&1 + 1))
          {:ok, nil}
        end
      ]

      state = base_state()

      result = CommentPolling.poll_github_comments(state, opts)
      assert is_struct(result, State)
      assert Agent.get(probe, & &1) == 25
    end
  end
end
