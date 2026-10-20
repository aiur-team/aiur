defmodule Aiur.Regression.OrchestratorLifecycle.CommentWakeTest do
  use Aiur.TestSupport

  import Aiur.OrchestratorLifecycleSupport

  alias Aiur.OrchestratorLifecycleSupport.HermeticReworkGitHubClient
  require Logger

  describe "comment wake/rework transitions" do
    setup do
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      Application.put_env(:aiur, :loadavg_source_override, fn -> {:ok, "0.0 0.0 0.0 1/1 1"} end)

      on_exit(fn -> restore_app_env(:loadavg_source_override, previous_loadavg) end)
    end

    test "trusted PR review comment reactivates a deactivated entry to rework" do
      issue_id = "life-review-1"
      identifier = "7411"
      memory_tracker!([%Issue{id: issue_id, identifier: identifier, state: "human-review", title: "Fix"}])

      entry =
        running_entry(issue_id, identifier, :deactivated)
        |> put_in([:issue], %Issue{id: issue_id, identifier: identifier, state: "human-review"})

      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "pr.review_comment")}, state)

      assert_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 2000
      refute get_in(next.running[issue_id], [:control, :status]) == :deactivated
    end

    test "trusted comment on an idle issue promotes it to rework and dispatches immediately" do
      identifier = "7412"
      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "issue.commented")}, base_state())

      assert_receive {:memory_tracker_state_update, ^identifier, "rework"}, 2000
      assert MapSet.member?(next.claimed, identifier)
    end

    # An over-threshold load average alone is not enough: the gate corroborates
    # it against a measured `/proc/stat` window, so the state carries the
    # previous snapshot a polling orchestrator would already have and the source
    # advances almost entirely in non-idle time (#2089).
    test "trusted comment rework dispatch respects the load admission gate" do
      identifier = "7412-load-hold"
      schedulers = System.schedulers_online()
      previous_loadavg = Application.get_env(:aiur, :loadavg_source_override)
      previous_proc_stat = Application.get_env(:aiur, :proc_stat_source_override)

      Application.put_env(:aiur, :loadavg_source_override, fn ->
        {:ok, "#{schedulers * 2.0} 1.0 1.0 1/1 1"}
      end)

      Application.put_env(:aiur, :proc_stat_source_override, fn ->
        {:ok, "cpu  1100 100 0 710 0 0 0 0 0 0\nprocs_running 20\n"}
      end)

      on_exit(fn ->
        restore_app_env(:loadavg_source_override, previous_loadavg)
        restore_app_env(:proc_stat_source_override, previous_proc_stat)
      end)

      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])

      state =
        base_state(
          load_envelope_state: %{
            last_decrease_ms: nil,
            cpu_snapshot: %{total: 1_000, idle: 700, nice: 100, runnable: 20},
            bootstrap_complete?: true
          }
        )

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "issue.commented")}, state)

      assert_receive {:memory_tracker_state_update, ^identifier, "rework"}, 2000
      refute MapSet.member?(next.claimed, identifier)
      assert %{signal: :load, measured: measured, threshold: threshold} = next.capacity_hold
      assert measured == schedulers * 2.0
      assert threshold == schedulers * 1.5
    end

    test "untrusted-author comment is ignored" do
      issue_id = "life-review-3"
      identifier = "7413"
      memory_tracker!([%Issue{id: issue_id, identifier: identifier, state: "human-review"}])
      entry = running_entry(issue_id, identifier, :deactivated)
      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info({:event, comment_event(identifier, "pr.review_comment", false)}, state)

      refute_receive {:memory_tracker_state_update, ^issue_id, "rework"}, 100
      assert get_in(next.running[issue_id], [:control, :status]) == :deactivated
      assert next.claimed == state.claimed
    end

    test "bot review-pass comment never self-triggers rework" do
      identifier = "7414"
      isolated_subscription_store(identifier)
      memory_tracker!([review_issue(identifier)])
      event = comment_event(identifier, "issue.commented", true, "[codex] Review passed for commit abc123")

      assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())

      refute_receive {:memory_tracker_state_update, ^identifier, "rework"}, 100
      refute MapSet.member?(next.claimed, identifier)
    end

    test "transient tracker failure retries the wake without consuming the event" do
      identifier = "7415"
      isolated_subscription_store(identifier)
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :hermetic_rework_recipient)
      previous_agent = Application.get_env(:aiur, :hermetic_rework_agent)
      previous_issues = Application.get_env(:aiur, :hermetic_rework_issues)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      {:ok, agent} = Agent.start_link(fn -> [{:error, {:github_api_status, 502}}, :ok, :ok] end)

      Application.put_env(:aiur, :comment_rework_retry_delay_ms, 0)

      on_exit(fn ->
        restore_app_env(:github_client_module, previous_github_client)
        restore_app_env(:hermetic_rework_recipient, previous_recipient)
        restore_app_env(:hermetic_rework_agent, previous_agent)
        restore_app_env(:hermetic_rework_issues, previous_issues)
        restore_app_env(:comment_rework_retry_delay_ms, previous_delay)
        Aiur.TestSupport.safe_stop(agent)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, HermeticReworkGitHubClient)
      Application.put_env(:aiur, :hermetic_rework_recipient, self())
      Application.put_env(:aiur, :hermetic_rework_agent, agent)

      Application.put_env(:aiur, :hermetic_rework_issues, [
        %Issue{id: identifier, identifier: identifier, state: "rework", title: "Rework"}
      ])

      event = comment_event(identifier, "issue.commented")
      assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())
      assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
      assert_receive {:retry_comment_rework, ^identifier, "issue comment", ^event, 2}, 2000

      assert {:noreply, retried} =
               Orchestrator.handle_info({:retry_comment_rework, identifier, "issue comment", event, 2}, next)

      assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
      assert MapSet.member?(retried.claimed, identifier)
    end

    test "permanent tracker auth failure fails fast instead of scheduling a retry" do
      identifier = "7417"
      isolated_subscription_store(identifier)
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :hermetic_rework_recipient)
      previous_agent = Application.get_env(:aiur, :hermetic_rework_agent)
      previous_issues = Application.get_env(:aiur, :hermetic_rework_issues)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      {:ok, agent} = Agent.start_link(fn -> [{:error, :missing_github_token}, :ok] end)

      Application.put_env(:aiur, :comment_rework_retry_delay_ms, 0)

      on_exit(fn ->
        restore_app_env(:github_client_module, previous_github_client)
        restore_app_env(:hermetic_rework_recipient, previous_recipient)
        restore_app_env(:hermetic_rework_agent, previous_agent)
        restore_app_env(:hermetic_rework_issues, previous_issues)
        restore_app_env(:comment_rework_retry_delay_ms, previous_delay)
        Aiur.TestSupport.safe_stop(agent)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_repo: "owner/repo",
        tracker_active_states: ["todo", "in-progress", "human-review", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :github_client_module, HermeticReworkGitHubClient)
      Application.put_env(:aiur, :hermetic_rework_recipient, self())
      Application.put_env(:aiur, :hermetic_rework_agent, agent)

      Application.put_env(:aiur, :hermetic_rework_issues, [
        %Issue{id: identifier, identifier: identifier, state: "rework", title: "Rework"}
      ])

      event = comment_event(identifier, "issue.commented")

      log =
        capture_log(fn ->
          # #3805: another process's retry log must not count against this ticket.
          Task.async(fn -> Logger.info("PR review comment rework transition retry scheduled: issue_identifier=29189 attempt=5/5 delay_ms=0") end) |> Task.await()
          assert {:noreply, next} = Orchestrator.handle_info({:event, event}, base_state())
          assert_receive {:hermetic_rework_update, ^identifier, "rework"}, 2000
          send(self(), {:permanent_failure_state, next})
        end)

      assert_receive {:permanent_failure_state, next}, 1000

      refute_receive {:retry_comment_rework, ^identifier, "issue comment", ^event, _attempt}, 200
      assert next.comment_rework_retries == %{}
      assert log =~ "rework transition retry scheduled: issue_identifier=29189"
      assert log =~ "rework transition failed permanently: issue_identifier=#{identifier} "
      refute log =~ "rework transition retry scheduled: issue_identifier=#{identifier} "
    end

    test "pr.merged terminalizes the ticket to done and tears down the running entry" do
      issue_id = "7416"
      identifier = "7416"
      memory_tracker!([])
      entry = Map.put(running_entry(issue_id, identifier, :working), :pid, worker_pid())
      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:event,
                  %{
                    topic: "ticket.#{identifier}.pr.merged",
                    pr: %{"body" => "Closes ##{identifier}"}
                  }},
                 state
               )

      assert_receive {:memory_tracker_state_update, ^identifier, "done"}, 2000
      refute Map.has_key?(next.running, issue_id)
      refute MapSet.member?(next.claimed, issue_id)
    end

    # #2609: the topic's ticket comes from the `aiur/<id>-<slug>` head branch,
    # so a body saying `Refs #N` names the ticket without claiming to close it.
    # Terminalizing anyway retired an operator's still-open acceptance list.
    test "pr.merged without a closing keyword leaves the ticket open and running" do
      issue_id = "7417"
      identifier = "7417"
      memory_tracker!([])
      entry = Map.put(running_entry(issue_id, identifier, :working), :pid, worker_pid())
      state = base_state(running: %{issue_id => entry}, claimed: MapSet.new([issue_id]))

      assert {:noreply, next} =
               Orchestrator.handle_info(
                 {:event,
                  %{
                    topic: "ticket.#{identifier}.pr.merged",
                    pr: %{"body" => "Refs ##{identifier} (merge does not close the ticket)"}
                  }},
                 state
               )

      refute_receive {:memory_tracker_state_update, ^identifier, "done"}, 300
      assert Map.has_key?(next.running, issue_id)
      assert MapSet.member?(next.claimed, issue_id)
    end
  end
end
