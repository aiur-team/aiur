Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RetryEngine.LookupTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.RetryEngine
  alias Aiur.Orchestrator.State
  import Aiur.RetryEngineFixture, only: [tracker_identity: 1]

  describe "handle_retry_issue_lookup/6" do
    test "preserves the running rework head through queued retry dispatch" do
      parent = self()
      issue = %Issue{id: "issue-rework-retry", identifier: "MT-REWORK-RETRY", title: "Rework retry", state: "rework"}

      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"],
        opencode_command: System.find_executable("true")
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())
      ref = make_ref()

      initial_state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        claimed: MapSet.new([issue.id]),
        running: %{
          issue.id => %{
            ref: ref,
            pid: parent,
            issue: issue,
            identifier: issue.identifier,
            started_at: DateTime.utc_now(),
            retry_attempt: 0,
            rework_head_sha: "head-before-run",
            control: %{status: :working}
          }
        }
      }

      assert {:noreply, queued_state} = RetryEngine.handle_agent_down(initial_state, ref, :normal)
      retry = queued_state.retry_attempts[issue.id]
      assert retry.rework_head_sha == "head-before-run"

      assert {:ok, attempt, metadata, popped_state} =
               RetryEngine.pop_retry_attempt_state(queued_state, issue.id, retry.retry_token)

      assert metadata.rework_head_sha == "head-before-run"

      assert {:noreply, _dispatched_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 popped_state,
                 issue.id,
                 attempt,
                 metadata,
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn state, _issue, _attempt, _worker_host, dispatch_opts ->
                   send(parent, {:rework_retry_baseline, dispatch_opts[:rework_head_sha]})
                   put_in(state.running[issue.id], %{pid: parent})
                 end
               )

      assert_receive {:rework_retry_baseline, "head-before-run"}, 1000
    end

    test "preserves the running rework head through failure retry dispatch" do
      parent = self()
      issue = %Issue{id: "issue-rework-failure-retry", identifier: "MT-REWORK-FAILURE-RETRY", title: "Rework retry", state: "rework"}

      write_workflow_file!(Aiur.Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework"],
        opencode_command: System.find_executable("true")
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())
      ref = make_ref()

      initial_state = %State{
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1,
        claimed: MapSet.new([issue.id]),
        running: %{
          issue.id => %{
            ref: ref,
            pid: parent,
            issue: issue,
            identifier: issue.identifier,
            started_at: DateTime.utc_now(),
            retry_attempt: 0,
            rework_head_sha: "head-before-failure",
            control: %{status: :working}
          }
        }
      }

      assert {:noreply, queued_state} = RetryEngine.handle_agent_down(initial_state, ref, :killed)
      retry = queued_state.retry_attempts[issue.id]
      assert retry.rework_head_sha == "head-before-failure"

      assert {:ok, attempt, metadata, popped_state} =
               RetryEngine.pop_retry_attempt_state(queued_state, issue.id, retry.retry_token)

      assert metadata.rework_head_sha == "head-before-failure"

      assert {:noreply, _dispatched_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 popped_state,
                 issue.id,
                 attempt,
                 metadata,
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn state, _issue, _attempt, _worker_host, dispatch_opts ->
                   send(parent, {:rework_failure_retry_baseline, dispatch_opts[:rework_head_sha]})
                   put_in(state.running[issue.id], %{pid: parent})
                 end
               )

      assert_receive {:rework_failure_retry_baseline, "head-before-failure"}, 1000
    end

    test "preserves prior-work continuation through an active retry dispatch" do
      issue = %Issue{id: "issue-active", identifier: "27", title: "Active retry", state: "In Progress"}
      state = %State{max_concurrent_agents: 1, effective_concurrent_agents: 1}
      parent = self()

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 2,
                 %{worker_host: nil, prior_work: true, rework_head_sha: "head-before-first-attempt"},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn current_state, ^issue, 2, nil, dispatch_opts ->
                   send(parent, {:retry_dispatch_opts, dispatch_opts})

                   %{
                     current_state
                     | running: Map.put(current_state.running, issue.id, %{pid: parent})
                   }
                 end
               )

      assert_receive {:retry_dispatch_opts, dispatch_opts}, 1000
      assert dispatch_opts[:prior_work] == true
      assert dispatch_opts[:rework_head_sha] == "head-before-first-attempt"
      assert get_in(next_state.running, [issue.id, :pid]) == parent
    end

    test "reschedules when an active retry dispatch starts neither a runner nor a retry" do
      issue = %Issue{id: "issue-limited", identifier: "27", title: "Limited retry", state: "In Progress"}

      state = %State{
        claimed: MapSet.new([issue.id]),
        max_concurrent_agents: 1,
        effective_concurrent_agents: 1
      }

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 2,
                 %{worker_host: nil, workspace_path: "/tmp/issue-limited", prior_work: true},
                 terminal_states: MapSet.new(["done"]),
                 dispatch_fun: fn current_state, ^issue, 2, nil, _dispatch_opts ->
                   %{
                     current_state
                     | model_fallback_waiting: MapSet.put(current_state.model_fallback_waiting, issue.id)
                   }
                 end,
                 schedule_retry_fun: fn retry_state, issue_id, attempt, metadata ->
                   assert attempt == 2
                   assert metadata.delay_type == :model_limit_wait
                   assert metadata.prior_work == true

                   %{
                     retry_state
                     | retry_attempts: Map.put(retry_state.retry_attempts, issue_id, metadata)
                   }
                 end
               )

      assert MapSet.member?(next_state.claimed, issue.id)
      assert MapSet.member?(next_state.model_fallback_waiting, issue.id)
      assert Map.has_key?(next_state.retry_attempts, issue.id)
    end

    test "fetches and records a terminal retry ticket when active candidates omit it" do
      terminal = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      state = %State{claimed: MapSet.new([terminal.id])}
      parent = self()
      identity = terminal.tracker_identity

      assert {:ok, ^terminal} =
               RetryEngine.fetch_retry_issue([], terminal.id, fn ["issue-terminal"] ->
                 {:ok, [terminal]}
               end)

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 terminal,
                 state,
                 terminal.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn identity, lifecycle ->
                   send(parent, {:membership_recorded, identity, lifecycle})
                   :ok
                 end,
                 set_terminal_verification_pending_fun: fn _identity, _pending? -> :ok end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   assert_receive {:membership_recorded, ^identity, :completed}, 1000
                   :ok
                 end
               )

      refute MapSet.member?(next_state.claimed, terminal.id)
    end

    test "reports a failed by-id retry lookup instead of releasing the claim" do
      assert {:error, :temporarily_unavailable} =
               RetryEngine.fetch_retry_issue([], "issue-terminal", fn ["issue-terminal"] ->
                 {:error, :temporarily_unavailable}
               end)
    end

    test "records terminal membership before cleanup and claim release" do
      issue = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      state = %State{claimed: MapSet.new([issue.id])}
      parent = self()
      identity = issue.tracker_identity

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn identity, lifecycle ->
                   send(parent, {:membership_recorded, identity, lifecycle})
                   :ok
                 end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   assert_receive {:membership_recorded, ^identity, :completed}, 1000
                   :ok
                 end
               )

      refute MapSet.member?(next_state.claimed, issue.id)
    end

    test "retains a terminal retry claim when membership persistence fails" do
      issue = %Issue{
        id: "issue-terminal",
        identifier: "27",
        state: "done",
        tracker_identity: tracker_identity("27")
      }

      parent = self()
      state = %State{claimed: MapSet.new([issue.id])}

      assert {:noreply, next_state} =
               RetryEngine.handle_retry_issue_lookup(
                 issue,
                 state,
                 issue.id,
                 1,
                 %{worker_host: nil},
                 terminal_states: MapSet.new(["done"]),
                 observe_membership_fun: fn _identity, _lifecycle -> {:error, :disk_full} end,
                 mark_reconciled_fun: fn status -> send(parent, {:freshness, status}) end,
                 set_terminal_verification_pending_fun: fn _identity, pending? ->
                   send(parent, {:terminal_verification_pending, pending?})
                 end,
                 cleanup_terminal_issue_artifacts_fun: fn _identifier, _worker_host ->
                   flunk("must not clean up before terminal membership persists")
                 end
               )

      assert_receive {:freshness, :unavailable}, 1000
      assert_receive {:terminal_verification_pending, true}, 1000
      assert MapSet.member?(next_state.claimed, issue.id)
      assert Map.has_key?(next_state.retry_attempts, issue.id)
    end
  end
end
