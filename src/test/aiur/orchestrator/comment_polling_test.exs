defmodule Aiur.Orchestrator.CommentPollingTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{CommentPolling, State}

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
      codex_thrash_budget: %{},
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
      assert result == state
    end
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
      assert third.github_connectivity[:recent_merge_store] == {:transport, 3}
      assert third.github_poll_delays[:recent_merge_store] == 4_000
      assert Agent.get(attempts, & &1) == 3

      assert_receive {:persistence_alert, "recent_merge_store.persistence_failed", message, alert_opts}
      assert message =~ "read-only"
      assert alert_opts[:needs_attention]
      refute_receive {:persistence_alert, _, _, _}

      fourth = CommentPolling.poll_github_firehose(third, opts)

      assert fourth.events_etag == "new-etag"
      assert fourth.events_last_id == "new-merge"
      assert fourth.github_connectivity[:recent_merge_store] == {:transport, 3}
      assert Agent.get(attempts, & &1) == 3
      refute_receive {:persistence_alert, _, _, _}
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
