defmodule Aiur.Orchestrator.Deactivate.CiWakeEventsTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{EventTopics, Reconciler}
  alias Aiur.OrchestratorDeactivateSupport.CIWatcherGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  describe "GitHub CI feedback poller" do
    setup do
      previous_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :ci_watcher_recipient)
      previous_issues = Application.get_env(:aiur, :ci_watcher_issues)
      previous_update_result = Application.get_env(:aiur, :ci_watcher_update_result)
      previous_ci_approval_store_path = Application.get_env(:aiur, :ci_approval_store_path)
      ci_approval_store_path = Aiur.TestSupport.tmp_root!("aiur_ci_approvals") <> ".json"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, CIWatcherGitHubClient)
      Application.put_env(:aiur, :ci_watcher_recipient, self())
      Application.put_env(:aiur, :ci_approval_store_path, ci_approval_store_path)

      on_exit(fn ->
        restore_application_env(:github_client_module, previous_client)
        restore_application_env(:ci_watcher_recipient, previous_recipient)
        restore_application_env(:ci_watcher_issues, previous_issues)
        restore_application_env(:ci_watcher_update_result, previous_update_result)
        restore_application_env(:ci_approval_store_path, previous_ci_approval_store_path)
        File.rm(ci_approval_store_path)
      end)

      :ok
    end

    test "CI failure topic parser accepts only ticket-local failure events" do
      assert {:ok, "824"} = EventTopics.parse_ci_failed_topic("ticket.824.ci.failed")

      for topic <- ["ticket.824.ci.passed", "ticket.824.ci.failed.extra", "ticket.824.pr.review_comment"] do
        assert :nomatch = EventTopics.parse_ci_failed_topic(topic)
      end
    end

    test "CI failure events do not resume an operator-paused runner" do
      identifier = "827"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :label_override)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.failed"}},
                 state
               )

      # handle_info/2 synchronously completes event handling.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :label_override
    end

    test "CI pass events resume an eligible CI-wait runner in the active handoff state" do
      identifier = "ci-pass-event-wake"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      active_issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(identifier)
      }

      Application.put_env(:aiur, :ci_watcher_issues, [active_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], active_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      receive_barrier({:ci_wait_control, {:resume_agent, _request_id, 101}})
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :ci_wait
    end

    test "CI failure events respect a fresh operator pause on a ci-wait runner" do
      identifier = "ci-event-fresh-pause"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      paused_issue = %Issue{id: identifier, identifier: identifier, state: "rework", paused: true}
      Application.put_env(:aiur, :ci_watcher_issues, [paused_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], paused_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.failed"}},
                 state
               )

      # handle_info/2 synchronously completes the fresh-pause gate.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      assert get_in(next_state.running[identifier], [:control, :status]) == :paused
      assert next_state.running[identifier].paused_reason == :ci_wait
    end

    test "a stale terminal event cannot resume a tracker-terminal CI-wait runner" do
      identifier = "ci-event-stale-terminal"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{id: identifier, identifier: identifier, state: "in-progress"}
      terminal_issue = %{stale_issue | state: "done"}
      Application.put_env(:aiur, :ci_watcher_issues, [terminal_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      # handle_info/2 synchronously completes the terminal-state gate.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      assert next_state.running[identifier].control.status == :paused
      assert next_state.running[identifier].issue.state == "done"
    end

    test "a terminal event cannot resume a runner reassigned to another worker" do
      identifier = "ci-event-routed-away"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      stale_issue = %Issue{id: identifier, identifier: identifier, state: "in-progress"}
      reassigned_issue = %{stale_issue | assigned_to_worker: false}
      Application.put_env(:aiur, :ci_watcher_issues, [reassigned_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], stale_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)

      assert {:noreply, next_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      # handle_info/2 synchronously completes the assignment gate.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      assert next_state.running[identifier].control.status == :paused
      refute next_state.running[identifier].issue.assigned_to_worker
    end

    test "a capacity-deferred terminal wake resumes after another slot opens" do
      identifier = "ci-event-capacity"
      agent_pid = control_test_agent(self())

      on_exit(fn ->
        if Process.alive?(agent_pid), do: Process.exit(agent_pid, :kill)
      end)

      active_issue = %Issue{
        id: identifier,
        identifier: identifier,
        state: "in-progress",
        tracker_identity: tracker_identity(identifier)
      }

      other_issue = %Issue{id: "ci-other", identifier: "ci-other", state: "in-progress"}
      Application.put_env(:aiur, :ci_watcher_issues, [active_issue])

      state =
        human_review_running_state(identifier, agent_pid)
        |> put_in([Access.key(:running), identifier, :issue], active_issue)
        |> put_in([Access.key(:running), identifier, :control], confirmed_control(:paused))
        |> put_in([Access.key(:running), identifier, :paused_reason], :ci_wait)
        |> put_in([Access.key(:max_concurrent_agents)], 1)
        |> put_in(
          [Access.key(:running), other_issue.id],
          %{identifier: other_issue.identifier, issue: other_issue, control: %{status: :working}}
        )

      assert {:noreply, deferred_state} =
               Orchestrator.handle_info(
                 {:event, %{topic: "ticket.#{identifier}.ci.passed"}},
                 state
               )

      # handle_info/2 synchronously completes the capacity decision.
      control_agent_barrier(agent_pid)
      refute_received {:ci_wait_control, {:resume_agent, _request_id}}
      assert deferred_state.running[identifier].control.status == :paused

      resumed_state =
        deferred_state
        |> update_in([Access.key(:running)], &Map.delete(&1, other_issue.id))
        |> Reconciler.maybe_reactivate_or_refresh(active_issue)

      receive_barrier({:ci_wait_control, {:resume_agent, _request_id, 101}})
      assert resumed_state.running[identifier].control.status == :paused
      assert resumed_state.running[identifier].paused_reason == :ci_wait
    end
  end
end
