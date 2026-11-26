defmodule Aiur.Orchestrator.Deactivate.PauseOverrideTest do
  use Aiur.TestSupport

  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.Orchestrator.{Dispatcher, DispatchPolicy}
  alias Aiur.Orchestrator.Reconciler
  alias Aiur.Orchestrator.StatusReport
  alias Aiur.OrchestratorDeactivateSupport.PauseOverrideGitHubClient

  import Aiur.OrchestratorDeactivateSupport

  describe "agent:paused label override" do
    test "paused active issue is not a dispatch candidate" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      state = %Orchestrator.State{
        running: %{},
        claimed: MapSet.new(),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: "issue-paused-candidate",
        identifier: "PAUSE-1",
        state: "todo",
        title: "Paused candidate",
        paused: true,
        labels: ["agent:todo", "agent:paused"]
      }

      refute DispatchPolicy.dispatch_candidate?(issue, state)
      refute DispatchPolicy.should_dispatch_issue?(issue, state)
    end

    test "running issue pauses with an alert when the override appears" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue_id = "issue-paused-running"
      identifier = "PAUSE-2"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.utc_now(),
            control: confirmed_control(:working)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 6
      }

      paused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Paused running",
        tracker_identity: tracker_identity(issue_id),
        paused: true,
        labels: ["agent:in-progress", "agent:paused"]
      }

      Publisher.set_tracked_fn(fn _ -> true end)
      divergence_topic = "ticket.#{identifier}.agent.attention.state_divergence"
      :ok = Exchange.subscribe(divergence_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)

        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      next = Reconciler.reconcile_running_issue_states([paused_issue], state)

      receive_barrier({:event, %{topic: ^divergence_topic} = event})
      assert event["reason"] =~ "local=working tracker=agent:paused"
      receive_barrier({:pause_agent, request_id, 101})
      assert get_in(next.running, [issue_id, :control, :status]) == :working
      assert next.running[issue_id].pending_pause_reason == %{request_id: request_id, reason: :label_override}
      refute Map.has_key?(next.running[issue_id], :paused_reason)
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == true
    end

    test "removing the override reports divergence, resumes, and returns the row to running" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"],
        max_concurrent_agents: 2
      )

      issue_id = "issue-paused-resume"
      identifier = "PAUSE-3"
      paused_at = DateTime.add(DateTime.utc_now(), -10, :second)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              paused: true,
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_at: paused_at,
            paused_reason: :label_override,
            control: confirmed_control(:paused)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      unpaused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Unpaused running",
        tracker_identity: tracker_identity(issue_id),
        paused: false,
        labels: ["agent:in-progress"]
      }

      Publisher.set_tracked_fn(fn _ -> true end)
      divergence_topic = "ticket.#{identifier}.agent.attention.state_divergence"
      :ok = Exchange.subscribe(divergence_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)

        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      next = Reconciler.reconcile_running_issue_states([unpaused_issue], state)

      receive_barrier({:event, %{topic: ^divergence_topic} = event})
      assert event["reason"] =~ "local=paused(label_override) tracker=agent:in-progress"

      receive_barrier({:resume_agent, request_id, 101})
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert get_in(next.running, [issue_id, :paused_reason]) == :label_override
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == false

      assert {:noreply, resumed} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                 next
               )

      assert resumed.running[issue_id].control.status == :working
      refute Map.has_key?(resumed.running[issue_id], :paused_reason)

      assert [%{state: :running, tracker_paused: false, reason: nil}] =
               StatusReport.agent_statuses(resumed, fn _timeout -> {:unavailable, nil} end)
    end

    test "resume clears a durable override regardless of the local pause reason and survives reconciliation" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        if previous_recipient,
          do: Application.put_env(:aiur, :memory_tracker_recipient, previous_recipient),
          else: Application.delete_env(:aiur, :memory_tracker_recipient)
      end)

      issue_id = "issue-paused-resume-clears-label"
      identifier = "PAUSE-RESUME"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{
              id: issue_id,
              identifier: identifier,
              state: "in-progress",
              paused: true,
              labels: ["agent:in-progress", "agent:paused"],
              tracker_identity: tracker_identity(issue_id)
            },
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_reason: :operator_pause,
            control: confirmed_control(:paused)
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      assert {:reply, {:tracker_io, {action, ^identifier, stage}, :remove_label, args}, prepared} =
               Orchestrator.handle_call({:resume_agent, identifier}, self(), state)

      result = apply(Aiur.Tracker, :remove_label, args)
      assert {:reply, {:ok, :resumed}, next} = Orchestrator.handle_call({:tracker_control_result, action, identifier, stage, result}, self(), prepared)
      receive_barrier({:memory_tracker_remove_label, ^identifier, "agent:paused"})
      receive_barrier({:resume_agent, request_id, 101})
      resumed = next.running[issue_id]
      assert resumed.control.status == :paused
      assert resumed.paused_reason == :operator_pause
      refute resumed.issue.paused
      refute "agent:paused" in resumed.issue.labels

      assert {:noreply, working} =
               Orchestrator.handle_info(
                 {:worker_control_state, issue_id, :working, %{request_id: request_id, generation: 101}},
                 next
               )

      reconciled = Reconciler.reconcile_running_issue_states([working.running[issue_id].issue], working)

      assert reconciled.running[issue_id].control.status == :working
      refute Map.has_key?(reconciled.running[issue_id], :paused_reason)
      # The reconcile call is synchronous and has completed every control send
      # caused by the worker-state acknowledgement.
      refute_received {:pause_agent, _request_id, _generation}
    end

    test "resume leaves the worker paused when clearing the override fails" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_label_prefix: "agent",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :pause_override_recipient)
      previous_result = Application.get_env(:aiur, :pause_override_remove_result)
      Application.put_env(:aiur, :github_client_module, PauseOverrideGitHubClient)
      Application.put_env(:aiur, :pause_override_recipient, self())
      Application.put_env(:aiur, :pause_override_remove_result, {:error, :unavailable})

      on_exit(fn ->
        restore_application_env(:github_client_module, previous_client)
        restore_application_env(:pause_override_recipient, previous_recipient)
        restore_application_env(:pause_override_remove_result, previous_result)
      end)

      issue_id = "issue-paused-resume-failure"
      identifier = "PAUSE-RESUME-FAILURE"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress", paused: true, labels: ["agent:in-progress", "agent:paused"]},
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_reason: :operator_pause,
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      assert {:reply, {:tracker_io, {action, ^identifier, stage}, :remove_label, args}, prepared} =
               Orchestrator.handle_call({:resume_agent, identifier}, self(), state)

      result = apply(Aiur.Tracker, :remove_label, args)

      assert {:reply, {:error, {:pause_override_clear_failed, :unavailable}}, next} =
               Orchestrator.handle_call({:tracker_control_result, action, identifier, stage, result}, self(), prepared)

      receive_barrier({:pause_override_remove_label, ^identifier, "agent:paused"})
      # handle_call/3 returns after the failed override-clear path.
      refute_received {:resume_agent, _request_id}
      assert next.running[issue_id].control.status == :paused
      assert next.running[issue_id].issue.paused
    end

    test "initial dispatch keeps paused active tickets suppressed" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      previous_issues = Application.get_env(:aiur, :memory_tracker_issues)
      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        restore_application_env(:memory_tracker_recipient, previous_recipient)
        restore_application_env(:memory_tracker_issues, previous_issues)
      end)

      issues =
        for state_name <- ["todo", "in-progress", "rework", "merging"] do
          %Issue{
            id: "issue-startup-paused-#{state_name}",
            identifier: "PAUSE-STARTUP-#{state_name}",
            state: state_name,
            title: "Paused #{state_name}",
            paused: true,
            labels: ["agent:#{state_name}", "agent:paused"]
          }
        end

      Application.put_env(:aiur, :memory_tracker_issues, issues)

      state = %Orchestrator.State{
        initial_dispatch_cycle: true,
        max_concurrent_agents: 4,
        effective_concurrent_agents: 4
      }

      next = Dispatcher.maybe_dispatch(state)

      refute next.initial_dispatch_cycle
      assert next.running == %{}
      assert next.claimed == MapSet.new()
      # maybe_dispatch/1 synchronously completes the paused-ticket scan.
      refute_received {:memory_tracker_remove_label, _, "agent:paused"}

      for issue <- issues do
        assert recovered = next.last_polled_issues[issue.id]
        assert recovered.paused
        assert "agent:paused" in recovered.labels

        unpaused_issue = %{issue | paused: false, labels: ["agent:#{issue.state}"]}

        candidate? =
          DispatchPolicy.candidate_issue?(
            unpaused_issue,
            DispatchPolicy.active_state_set(),
            DispatchPolicy.terminal_state_set()
          )

        # The control for this test: with the pause lifted these would dispatch,
        # so `agent:paused` is what suppressed them above. `merging` is the
        # exception — it is an active state, but no agent work exists there, so
        # it stays refused on its own account (#1759).
        if DispatchPolicy.no_agent_work_state?(issue.state) do
          refute candidate?
        else
          assert candidate?
        end
      end
    end

    test "removing the override does not resume a manually paused agent" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      issue_id = "issue-manual-paused"
      identifier = "PAUSE-4"

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: self(),
            ref: nil,
            identifier: identifier,
            issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress", paused: true},
            started_at: DateTime.add(DateTime.utc_now(), -30, :second),
            paused_at: DateTime.add(DateTime.utc_now(), -10, :second),
            control: %{status: :paused}
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{},
        max_concurrent_agents: 2
      }

      unpaused_issue = %Issue{
        id: issue_id,
        identifier: identifier,
        state: "in-progress",
        title: "Still manually paused",
        paused: false,
        labels: ["agent:in-progress"]
      }

      next = Reconciler.reconcile_running_issue_states([unpaused_issue], state)

      # reconcile_running_issue_states/2 returns after deciding whether the
      # unpaused tracker snapshot requires a resume command.
      refute_received {:resume_agent, _request_id}
      assert get_in(next.running, [issue_id, :control, :status]) == :paused
      assert get_in(next.running, [issue_id, :issue, Access.key(:paused)]) == false
    end
  end
end
