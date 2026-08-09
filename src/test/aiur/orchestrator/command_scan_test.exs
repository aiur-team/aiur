defmodule Aiur.Orchestrator.CommandScanTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{CommandScan, State}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_repo: "owner/repo",
      tracker_label_prefix: "agent",
      pr_watch_enabled: true
    )

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

  describe "scan_pr_commands/2" do
    test "returns state unchanged when pr_watch is disabled" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        pr_watch_enabled: false
      )

      assert CommandScan.scan_pr_commands(base_state()) == base_state()
    end

    test "with injected empty comment stream does not advance cursor" do
      state = %{base_state() | github_command_scan_since: "2024-01-01T00:00:00Z"}

      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
      ]

      result = CommandScan.scan_pr_commands(state, opts)
      assert result.github_command_scan_since == state.github_command_scan_since
    end
  end

  describe "scan_pr_commands/2 conditional reads" do
    defp review_comment(id, created_at) do
      %{
        "id" => id,
        "body" => "/aiur retry",
        "created_at" => created_at,
        "updated_at" => created_at,
        "html_url" => "https://github.com/owner/repo/pull/77#discussion_r#{id}",
        "pull_request_url" => "https://api.github.com/repos/owner/repo/pulls/77",
        "user" => %{"login" => "its-everdred"}
      }
    end

    defp etag_state do
      %{
        base_state()
        | github_command_scan_since: "2024-01-01T00:00:00Z",
          github_comment_etags: %{command_scan_review: "review-etag", command_scan_issue: "issue-etag"}
      }
    end

    test "sends each stream its own stored etag" do
      test_pid = self()

      opts = [
        command_scan_review_comment_fetcher: fn opts ->
          send(test_pid, {:review_etag, Keyword.get(opts, :etag)})
          {:not_modified, "review-etag"}
        end,
        command_scan_issue_comment_fetcher: fn opts ->
          send(test_pid, {:issue_etag, Keyword.get(opts, :etag)})
          {:not_modified, "issue-etag"}
        end
      ]

      CommandScan.scan_pr_commands(etag_state(), opts)

      assert_receive {:review_etag, "review-etag"}
      assert_receive {:issue_etag, "issue-etag"}
    end

    test "a 304 on both streams leaves the cursor and the etags untouched" do
      state = etag_state()

      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:not_modified, "review-etag"} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:not_modified, "issue-etag"} end
      ]

      result = CommandScan.scan_pr_commands(state, opts)

      assert result.github_command_scan_since == state.github_command_scan_since
      assert result.github_comment_etags[:command_scan_review] == "review-etag"
      assert result.github_comment_etags[:command_scan_issue] == "issue-etag"
    end

    test "stores the refreshed etag and still processes comments on a 200" do
      opts = [
        command_scan_review_comment_fetcher: fn _opts ->
          {:ok, [review_comment(1, "2024-06-15T12:00:00Z")], "review-etag-2"}
        end,
        command_scan_issue_comment_fetcher: fn _opts -> {:not_modified, "issue-etag"} end
      ]

      result = CommandScan.scan_pr_commands(etag_state(), opts)

      assert result.github_comment_etags[:command_scan_review] == "review-etag-2"
      assert result.github_comment_etags[:command_scan_issue] == "issue-etag"
      # The cursor only advances if the 200 body actually reached the scan
      # pipeline: a 304-returns-empty bug here would silently drop commands.
      assert result.github_command_scan_since == "2024-06-15T11:59:59Z"
    end

    test "a 304 on one stream does not discard the other stream's comments" do
      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:not_modified, "review-etag"} end,
        command_scan_issue_comment_fetcher: fn _opts ->
          {:ok,
           [
             %{
               "id" => 9,
               "body" => "/aiur retry",
               "created_at" => "2024-06-15T12:00:00Z",
               "updated_at" => "2024-06-15T12:00:00Z",
               "html_url" => "https://github.com/owner/repo/pull/77#issuecomment-9",
               "issue_url" => "https://api.github.com/repos/owner/repo/issues/77",
               "user" => %{"login" => "its-everdred"}
             }
           ], "issue-etag-2"}
        end
      ]

      result = CommandScan.scan_pr_commands(etag_state(), opts)

      assert result.github_command_scan_since == "2024-06-15T11:59:59Z"
      assert result.github_comment_etags[:command_scan_issue] == "issue-etag-2"
    end

    test "a failed stream retains its previous etag rather than clearing it" do
      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:error, :boom} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:not_modified, "issue-etag"} end
      ]

      result = CommandScan.scan_pr_commands(etag_state(), opts)

      assert result.github_comment_etags[:command_scan_review] == "review-etag"
    end

    test "an unconditional 2-tuple fetcher still works and keeps its etag" do
      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:ok, [review_comment(2, "2024-06-15T12:00:00Z")]} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
      ]

      result = CommandScan.scan_pr_commands(etag_state(), opts)

      assert result.github_comment_etags[:command_scan_review] == "review-etag"
      assert result.github_command_scan_since == "2024-06-15T11:59:59Z"
    end
  end

  describe "advance_command_scan_since/2" do
    test "returns input since when newest is nil" do
      since = "2024-01-01T00:00:00Z"
      assert CommandScan.advance_command_scan_since(since, nil) == since
    end

    test "returns nil since when newest is nil and since is nil" do
      assert CommandScan.advance_command_scan_since(nil, nil) == nil
    end

    test "returns newest minus 1 second as ISO8601 when given DateTime" do
      {:ok, dt, _} = DateTime.from_iso8601("2024-06-15T12:00:00Z")
      result = CommandScan.advance_command_scan_since(nil, dt)
      {:ok, result_dt, _} = DateTime.from_iso8601(result)
      expected = DateTime.add(dt, -1, :second)
      assert DateTime.compare(result_dt, expected) == :eq
    end

    test "cursor overlap is exactly 1 second (FI-ORC-043)" do
      {:ok, newest, _} = DateTime.from_iso8601("2024-06-15T12:05:30Z")
      result = CommandScan.advance_command_scan_since("old", newest)
      {:ok, result_dt, _} = DateTime.from_iso8601(result)
      diff = DateTime.diff(newest, result_dt, :second)
      assert diff == 1
    end
  end
end
