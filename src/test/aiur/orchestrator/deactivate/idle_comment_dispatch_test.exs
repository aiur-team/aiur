defmodule Aiur.Orchestrator.Deactivate.IdleCommentDispatchTest do
  use Aiur.TestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Events.SubscriptionStore
  alias Aiur.Issue
  alias Aiur.Orchestrator
  alias Aiur.OrchestratorDeactivateSupport.{DirectDispatchGitHubClient, FlakyReworkGitHubClient}

  import Aiur.OrchestratorDeactivateSupport

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "trusted comment for an idle issue queues the comment and schedules dispatch" do
      issue_id = "issue-issue-commented-2"
      issue_identifier = "7"
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :memory_tracker_recipient, self())

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 123,
          topic: "ticket.#{issue_identifier}.issue.commented",
          source: :github,
          author_trusted?: true,
          message: "please fix the PR",
          comment: %{"body" => "please fix the PR"}
        }

        assert {:noreply, next_state} =
                 Orchestrator.handle_info(
                   {:event, event},
                   state
                 )

        receive_barrier({:memory_tracker_state_update, ^issue_identifier, "rework"})
        # The preceding handle_info/2 return is the barrier for tracker writes.
        refute_received {:memory_tracker_state_update, ^issue_id, "rework"}

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(next_state.queue_store, issue_identifier)

        assert %{
                 subscribed_to: subscribed_to
               } = SubscriptionStore.snapshot(issue_identifier)

        topics = Enum.map(subscribed_to, & &1["topic"])
        assert "ticket.#{issue_identifier}.issue.commented" in topics
        assert "ticket.#{issue_identifier}.pr.review_comment" in topics
        receive_barrier(:run_poll_cycle)
      after
        :ok = SubscriptionStore.stop(issue_identifier)

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end
      end
    end

    test "trusted idle review comment dispatches a todo ticket without flipping it to rework" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-direct-comment-dispatch")

      issue_identifier = "58"
      fake_codex = Path.join(test_root, "fake-codex")
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_direct_recipient = Application.get_env(:aiur, :direct_dispatch_recipient)
      previous_direct_issues = Application.get_env(:aiur, :direct_dispatch_issues)

      previous_lifecycle_recorder =
        Application.get_env(:aiur, :run_telemetry_lifecycle_recorder)

      test_pid = self()

      Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attributes, opts ->
        send(test_pid, {:lifecycle, kind, attributes, opts})
        :ok
      end)

      try do
        File.mkdir_p!(test_root)
        File.write!(fake_codex, "#!/bin/sh\nsleep 30\n")
        File.chmod!(fake_codex, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          workspace_root: test_root,
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          codex_command: "#{fake_codex} app-server"
        )

        Application.put_env(:aiur, :github_client_module, DirectDispatchGitHubClient)
        Application.put_env(:aiur, :direct_dispatch_recipient, self())

        Application.put_env(:aiur, :direct_dispatch_issues, [
          %Issue{
            id: issue_identifier,
            identifier: issue_identifier,
            state: "todo",
            title: "Review comment requested rework",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_822_447,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "please acknowledge this inline review comment",
          comment: %{
            "body" => "please acknowledge this inline review comment",
            "id" => 3_473_822_447
          }
        }

        assert {:noreply, next_state} = Orchestrator.handle_info({:event, event}, state)

        # The ticket is `agent:todo`: there is no prior work for "rework" to be
        # a verdict on, so the label must be left alone. The comment still has
        # to reach the digest the dispatched agent reads on its first turn —
        # skipping the transition must not mean losing operator input.
        # handle_info/2 returns after the direct-dispatch state decision.
        refute_received {:direct_dispatch_update, ^issue_identifier, _state}
        receive_barrier({:direct_dispatch_fetch, [^issue_identifier]})
        refute_received :run_poll_cycle

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(next_state.queue_store, issue_identifier)

        assert %{^issue_identifier => entry} = next_state.running
        assert entry.issue.state == "todo"
        assert MapSet.member?(next_state.claimed, issue_identifier)

        receive_barrier(
          {:lifecycle, :lifecycle,
           %{
             event: "agent_resume",
             cause: "rework_dispatch",
             attempt_id: attempt_id
           }, []}
        )

        assert is_binary(attempt_id)

        if is_pid(entry.pid) and Process.alive?(entry.pid) do
          Process.exit(entry.pid, :kill)

          receive do
            {:DOWN, _ref, :process, pid, _reason} when pid == entry.pid -> :ok
          after
            100 -> :ok
          end
        end
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:direct_dispatch_recipient, previous_direct_recipient)
        restore_application_env(:direct_dispatch_issues, previous_direct_issues)
        restore_application_env(:run_telemetry_lifecycle_recorder, previous_lifecycle_recorder)
        File.rm_rf(test_root)
      end
    end

    test "trusted idle review comment does not admit a concurrently terminal issue" do
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_direct_recipient = Application.get_env(:aiur, :direct_dispatch_recipient)
      previous_direct_issues = Application.get_env(:aiur, :direct_dispatch_issues)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :github_client_module, DirectDispatchGitHubClient)
        Application.put_env(:aiur, :direct_dispatch_recipient, self())

        Application.put_env(:aiur, :direct_dispatch_issues, [
          %Issue{
            id: issue_identifier,
            identifier: issue_identifier,
            state: "done",
            title: "Merged while the comment event was in flight",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_822_448,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "comment raced with merge",
          comment: %{"body" => "comment raced with merge", "id" => 3_473_822_448}
        }

        assert {:noreply, next_state} = Orchestrator.handle_info({:event, event}, state)

        receive_barrier({:direct_dispatch_update, ^issue_identifier, "rework"})

        # Two reads, and only two: the #1971 parking gate resolves the ticket's
        # labels before writing `rework`, then dispatch admission re-reads it so
        # a concurrently terminal issue is not admitted. A third read would mean
        # the comment path had started looping.
        receive_barrier({:direct_dispatch_fetch, [^issue_identifier]})
        receive_barrier({:direct_dispatch_fetch, [^issue_identifier]})
        # The handle_info/2 call above synchronously performs both admissibility
        # reads before returning, so there cannot be a later third fetch.
        refute_received {:direct_dispatch_fetch, [^issue_identifier]}
        receive_barrier(:run_poll_cycle)
        assert next_state.running == %{}
        assert next_state.claimed == MapSet.new()
      after
        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:direct_dispatch_recipient, previous_direct_recipient)
        restore_application_env(:direct_dispatch_issues, previous_direct_issues)
      end
    end

    test "trusted idle review comment retries a transient rework transition failure" do
      issue_identifier = "58"
      previous_github_client = Application.get_env(:aiur, :github_client_module)
      previous_recipient = Application.get_env(:aiur, :flaky_rework_recipient)
      previous_agent = Application.get_env(:aiur, :flaky_rework_agent)
      previous_owner = Application.get_env(:aiur, :flaky_rework_owner)
      previous_delay = Application.get_env(:aiur, :comment_rework_retry_delay_ms)
      previous_max = Application.get_env(:aiur, :comment_rework_max_attempts)
      {:ok, agent} = Agent.start_link(fn -> [{:error, {:github_api_status, 502}}, :ok] end)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "github",
          tracker_repo: "owner/repo",
          tracker_label_prefix: "agent",
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        Application.put_env(:aiur, :flaky_rework_recipient, self())
        Application.put_env(:aiur, :flaky_rework_agent, agent)
        Application.put_env(:aiur, :flaky_rework_owner, self())
        Application.put_env(:aiur, :github_client_module, FlakyReworkGitHubClient)
        Application.put_env(:aiur, :comment_rework_retry_delay_ms, 1)
        Application.put_env(:aiur, :comment_rework_max_attempts, 3)

        assert {:error, :unexpected_test_caller} =
                 Task.async(fn ->
                   FlakyReworkGitHubClient.update_issue_state("unrelated", "rework")
                 end)
                 |> Task.await()

        state = %Orchestrator.State{
          running: %{},
          claimed: MapSet.new(),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          id: 3_473_356_579,
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          source: :github,
          author_trusted?: true,
          message: "please acknowledge this inline review comment",
          comment: %{
            "body" => "please acknowledge this inline review comment",
            "id" => 3_473_356_579
          }
        }

        assert {:noreply, failed_state} = Orchestrator.handle_info({:event, event}, state)

        receive_barrier({:flaky_rework_update, ^issue_identifier, "rework"})
        assert [] = AgentQueueStore.list_pending(failed_state.queue_store, issue_identifier)

        receive_barrier({:retry_comment_rework, ^issue_identifier, "PR review comment", ^event, 2})

        assert {:noreply, retry_state} =
                 Orchestrator.handle_info(
                   {:retry_comment_rework, issue_identifier, "PR review comment", event, 2},
                   failed_state
                 )

        receive_barrier({:flaky_rework_update, ^issue_identifier, "rework"})

        assert [
                 %{
                   event_type: :events_digest,
                   body: %{events: [^event]}
                 }
               ] = AgentQueueStore.list_pending(retry_state.queue_store, issue_identifier)

        assert %{
                 subscribed_to: subscribed_to
               } = SubscriptionStore.snapshot(issue_identifier)

        topics = Enum.map(subscribed_to, & &1["topic"])
        assert "ticket.#{issue_identifier}.issue.commented" in topics
        assert "ticket.#{issue_identifier}.pr.review_comment" in topics
        receive_barrier(:run_poll_cycle)
      after
        :ok = SubscriptionStore.stop(issue_identifier)

        restore_application_env(:github_client_module, previous_github_client)
        restore_application_env(:flaky_rework_recipient, previous_recipient)
        restore_application_env(:flaky_rework_agent, previous_agent)
        restore_application_env(:flaky_rework_owner, previous_owner)
        restore_application_env(:comment_rework_retry_delay_ms, previous_delay)
        restore_application_env(:comment_rework_max_attempts, previous_max)

        Aiur.TestSupport.safe_stop(agent)
      end
    end
  end
end
