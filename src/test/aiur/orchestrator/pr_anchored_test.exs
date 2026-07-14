defmodule Aiur.Orchestrator.PrAnchoredTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{PrAnchored, State}

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

  describe "maybe_route_pr_anchored_or_legacy/5" do
    test "untrusted comments perform no PR fetch and return state unchanged" do
      # untrusted event -> legacy path -> transition_comment_issue_to_rework -> {:skip, :untrusted_author}
      state = base_state()
      event = %{author_trusted?: false}

      result = PrAnchored.maybe_route_pr_anchored_or_legacy(state, "123", :github, event, 1)

      assert result == state
    end

    test "routes an open human PR through the injected dispatch function" do
      state = base_state()
      parent = self()

      pr = %{"number" => 42, "title" => "My PR", "body" => "", "head" => %{"ref" => "feat/my-feature"}}

      event = %{
        author_trusted?: true,
        open_pull_request_fetcher: fn _n -> {:ok, pr} end,
        pr_anchored_dispatch_fun: fn current_state, issue ->
          send(parent, {:pr_anchored_dispatch, issue})
          current_state
        end
      }

      result = PrAnchored.maybe_route_pr_anchored_or_legacy(state, "42", :github, event, 1)

      assert result == state
      assert_receive {:pr_anchored_dispatch, %{id: "pr-42", identifier: "42", state: "pr-watch"}}
    end

    test "falls through to legacy when fetcher returns nil (closed/missing PR)" do
      state = base_state()

      event = %{
        author_trusted?: true,
        open_pull_request_fetcher: fn _n -> {:ok, nil} end
      }

      result = PrAnchored.maybe_route_pr_anchored_or_legacy(state, "99", :github, event, 1)

      assert result == state
    end
  end

  describe "maybe_stop_closed_pr_anchored_agents/2" do
    test "returns state unchanged when no pr-watch running entries" do
      state = base_state()
      result = PrAnchored.maybe_stop_closed_pr_anchored_agents(state)
      assert result == state
    end
  end
end
