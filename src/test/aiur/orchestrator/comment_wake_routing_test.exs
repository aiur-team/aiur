defmodule Aiur.Orchestrator.CommentWakeRoutingTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{CommentWake, State}

  test "live merged route sends a ticket with an approved remaining PR to ci-wait" do
    parent = self()

    CommentWake.mark_pr_merged_issue_done(base_state(), "2307",
      pr_body: "Closes #2307",
      merged_by_login: "its-everdred",
      merger_allowed_fun: fn _ -> true end,
      update_issue_state_fun: fn identifier, state_name ->
        send(parent, {:transition, identifier, state_name})
        :ok
      end,
      open_pull_requests_fun: fn _ ->
        {:ok, [%{"number" => 2318, "head" => %{"sha" => "head-2318"}}]}
      end,
      reviews_fetcher: fn 2318 -> {:ok, []} end,
      pull_request_approval_fetcher: fn 2318 -> {:ok, {"head-2318", "head-2318"}} end
    )

    assert_receive {:transition, "2307", "ci-wait"}, 1000
    refute_receive {:transition, "2307", "done"}, 100
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
      github_connectivity: %{},
      github_poll_delays: %{},
      github_command_scan_since: nil
    }
  end
end
