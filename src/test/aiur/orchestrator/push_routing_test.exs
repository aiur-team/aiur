defmodule Aiur.Orchestrator.PushRoutingTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.{PushRouting, State}

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

  describe "maybe_pause_on_request/2" do
    test "returns state unchanged for unknown identifier" do
      state = base_state()
      result = PushRouting.maybe_pause_on_request(state, "unknown-999")
      assert result == state
    end

    test "keeps a requested pause working until the worker confirms it" do
      running_entry = %{
        identifier: "ISSUE-1",
        pid: self(),
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :working}
      }

      state = %{base_state() | running: %{"issue-1" => running_entry}}

      result = PushRouting.maybe_pause_on_request(state, "ISSUE-1")

      refute_receive {:pause_agent, _request_id}
      assert result.running["issue-1"].control.status == :working
      refute Map.has_key?(result.running["issue-1"], :paused_reason)
    end
  end

  describe "maybe_notify_agents_on_default_branch_push/3" do
    test "never terminates or restarts a running entry" do
      running_entry = %{
        identifier: "ISSUE-1",
        pid: nil,
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :working}
      }

      state = %{base_state() | running: %{"issue-1" => running_entry}}

      result = PushRouting.maybe_notify_agents_on_default_branch_push(state, "main", %{sha: "abc123"})

      # running map is structurally unchanged (notify-only invariant FI-ORC-039)
      assert result.running == state.running
    end
  end

  describe "maybe_mark_sleeping/2" do
    test "flips :working entry to :sleeping" do
      running_entry = %{
        identifier: "ISSUE-1",
        pid: nil,
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :working}
      }

      state = %{base_state() | running: %{"issue-1" => running_entry}}

      result = PushRouting.maybe_mark_sleeping(state, "ISSUE-1")
      assert result.running["issue-1"].control.status == :sleeping
    end

    test "leaves :paused entry unchanged" do
      running_entry = %{
        identifier: "ISSUE-1",
        pid: nil,
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :paused}
      }

      state = %{base_state() | running: %{"issue-1" => running_entry}}

      result = PushRouting.maybe_mark_sleeping(state, "ISSUE-1")
      assert result == state
    end

    test "leaves :deactivated entry unchanged" do
      running_entry = %{
        identifier: "ISSUE-1",
        pid: nil,
        issue: %Aiur.Issue{id: "issue-1", identifier: "ISSUE-1", state: "active"},
        control: %{status: :deactivated}
      }

      state = %{base_state() | running: %{"issue-1" => running_entry}}

      result = PushRouting.maybe_mark_sleeping(state, "ISSUE-1")
      assert result == state
    end
  end

  describe "maybe_resume_blockees_on_merged_ticket/2" do
    test "retains merged-ticket readiness until a dependency pause is confirmed" do
      blocker_identifier = "1570"
      blockee = %Aiur.Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}

      entry = %{
        identifier: blockee.identifier,
        pid: self(),
        issue: blockee,
        control: %{status: :working},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker_identifier, generation: 1}
      }

      state = %{base_state() | running: %{blockee.id => entry}}

      result = PushRouting.maybe_resume_blockees_on_merged_ticket(state, blocker_identifier)

      assert %{
               blocker_identifier: ^blocker_identifier,
               topic: "ticket.1570.pr.merged",
               unblock_key: "ticket.1570.pr.merged",
               pause_generation: 1,
               stamped_at: %DateTime{}
             } = result.running[blockee.id].pending_auto_resume
    end

    test "resumes a confirmed dependency pause after merged-ticket reconciliation" do
      blocker_identifier = "1570"
      blockee = %Aiur.Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}

      entry = %{
        identifier: blockee.identifier,
        pid: self(),
        issue: blockee,
        control: %{status: :paused, can_interrupt: true},
        paused_reason: :blocker_dependency,
        blocker_pause_generation: 1,
        blocker_pause: %{blocker_identifier: blocker_identifier, generation: 1}
      }

      state = %{base_state() | running: %{blockee.id => entry}, max_concurrent_agents: 2}

      result = PushRouting.maybe_resume_blockees_on_merged_ticket(state, blocker_identifier)

      assert_receive {:resume_agent, _request_id}
      assert result.running[blockee.id].control.status == :working
      refute Map.has_key?(result.running[blockee.id], :paused_reason)
    end
  end

  describe "reconcile_pending_auto_resumes/1" do
    test "returns state unchanged when no pending_auto_resume hints" do
      state = base_state()
      result = PushRouting.reconcile_pending_auto_resumes(state)
      assert result == state
    end
  end
end
