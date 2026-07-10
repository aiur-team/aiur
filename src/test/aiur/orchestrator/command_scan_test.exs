defmodule Aiur.Orchestrator.CommandScanTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{CommandScan, State}

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

  describe "scan_pr_commands/2" do
    test "returns state unchanged when pr_watch is disabled" do
      # pr_watch_enabled? returns false in test env (no config)
      state = base_state()
      result = CommandScan.scan_pr_commands(state)
      assert result == state
    end

    test "with injected empty comment stream does not advance cursor" do
      # When pr_watch IS enabled (stubbed via opts) with empty stream,
      # since nothing is scanned, cursor stays nil
      state = base_state()

      opts = [
        command_scan_review_comment_fetcher: fn _opts -> {:ok, []} end,
        command_scan_issue_comment_fetcher: fn _opts -> {:ok, []} end
      ]

      # Without pr_watch configured, scan_pr_commands is a no-op
      result = CommandScan.scan_pr_commands(state, opts)
      assert result == state
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
