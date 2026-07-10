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
      load_envelope_last_decrease_ms: nil,
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
