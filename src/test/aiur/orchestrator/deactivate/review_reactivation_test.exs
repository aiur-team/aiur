defmodule Aiur.Orchestrator.Deactivate.ReviewReactivationTest do
  use Aiur.TestSupport

  alias Aiur.AgentQueueStore
  alias Aiur.Issue
  alias Aiur.Orchestrator

  describe "issue.commented firehose reactivation (subscriber wiring)" do
    test "wakes a :deactivated agent:rework entry on a trusted comment with no unresolved threads" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-rework-no-threads")

      issue_id = "issue-rework-no-threads"
      issue_identifier = "164"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Rework completed, review still open",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "rework", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          author_trusted?: true,
          comment: %{"body" => "One more thing on the handoff, please."},
          open_pr_fetcher: fn _key -> {:ok, %{"number" => 178, "head" => %{"sha" => "f4e6944"}}} end,
          unresolved_threads_fetcher: fn _pr -> {:ok, []} end
        }

        {:noreply, next} = Orchestrator.handle_info({:event, event}, state)

        entry = Map.fetch!(next.running, issue_id)
        refute get_in(entry, [:control, :status]) == :deactivated

        # No label write happens on this path — that is what keeps #2422's
        # rework loop closed. The memory tracker reports every state update to
        # `self()`, so a stray write would be observable here.
        refute_receive {:memory_tracker_state_update, ^issue_id, _state}, 200

        # The comment travels with the wake. Without this the agent respawns
        # into an unchanged ticket with no idea what it was woken for, and the
        # most likely outcome is that it concludes there is nothing to rework
        # and the reviewer's request is lost.
        assert [%{event_type: :events_digest, body: %{events: [^event]}}] =
                 AgentQueueStore.list_pending(next.queue_store, issue_identifier)
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    # The other half of the same rule: the wake-without-write path is scoped to
    # a ticket that is ALREADY `rework`. A `human-review` ticket whose threads
    # are all resolved must stay asleep, or every trusted comment on a
    # finished PR restores the pre-#2422 behaviour.
    #
    # `human-review` is deliberately IN `tracker_active_states` here, unlike
    # the sibling fixtures. Without it the issue is refused upstream by
    # `Dispatcher.revalidate_issue_for_dispatch`, and this test passes even
    # with `require_state: "rework"` deleted — guarding nothing.
    test "leaves a :deactivated human-review entry asleep when there are no unresolved threads" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-human-review-no-threads")

      issue_id = "issue-human-review-no-threads"
      issue_identifier = "165"
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging", "human-review"],
          tracker_terminal_states: ["done", "cancelled", "canceled"]
        )

        File.mkdir_p!(test_root)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "human-review",
            title: "Awaiting human review",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            }
          },
          claimed: MapSet.new([issue_id]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 6
        }

        event = %{
          topic: "ticket.#{issue_identifier}.pr.review_comment",
          author_trusted?: true,
          comment: %{"body" => "Nice, thanks."},
          open_pr_fetcher: fn _key -> {:ok, %{"number" => 179, "head" => %{"sha" => "aaa1111"}}} end,
          unresolved_threads_fetcher: fn _pr -> {:ok, []} end
        }

        {:noreply, next} = Orchestrator.handle_info({:event, event}, state)

        entry = Map.fetch!(next.running, issue_id)
        assert get_in(entry, [:control, :status]) == :deactivated
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end

    test "persists an actionable alert when trusted issue feedback cannot claim a rework slot" do
      test_root = Aiur.TestSupport.tmp_root!("aiur-orch-issue-commented-capacity")

      issue_id = "issue-issue-commented-capacity"
      issue_identifier = "45"
      workspace = Path.join(test_root, issue_identifier)
      previous_memory_issues = Application.get_env(:aiur, :memory_tracker_issues)
      previous_memory_recipient = Application.get_env(:aiur, :memory_tracker_recipient)

      try do
        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "memory",
          workspace_root: test_root,
          tracker_active_states: ["todo", "in-progress", "rework", "merging"],
          tracker_terminal_states: ["done", "cancelled", "canceled"],
          worker_ssh_hosts: ["worker-1"],
          worker_max_concurrent_agents_per_host: 1
        )

        File.mkdir_p!(workspace)
        Application.put_env(:aiur, :memory_tracker_recipient, self())

        Application.put_env(:aiur, :memory_tracker_issues, [
          %Issue{
            id: issue_id,
            identifier: issue_identifier,
            state: "rework",
            title: "Review feedback pending",
            description: "",
            labels: []
          }
        ])

        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: nil,
              ref: nil,
              identifier: issue_identifier,
              issue: %Issue{id: issue_id, state: "human-review", identifier: issue_identifier},
              workspace_path: workspace,
              worker_host: "worker-1",
              started_at: DateTime.utc_now(),
              control: %{status: :deactivated}
            },
            "busy-issue" => %{
              pid: nil,
              ref: nil,
              identifier: "busy",
              issue: %Issue{id: "busy-issue", state: "in-progress", identifier: "busy"},
              worker_host: "worker-1",
              started_at: DateTime.utc_now(),
              control: %{status: :working}
            }
          },
          claimed: MapSet.new([issue_id, "busy-issue"]),
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{},
          max_concurrent_agents: 2
        }

        parent = self()

        log =
          capture_log(fn ->
            send(
              parent,
              Orchestrator.handle_info(
                {:event,
                 %{
                   topic: "ticket.#{issue_identifier}.issue.commented",
                   author_trusted?: true,
                   comment: %{body: "Please fix the lost workspace handoff."}
                 }},
                state
              )
            )
          end)

        receive_barrier({:noreply, next})

        receive_barrier({:memory_tracker_state_update, ^issue_id, "rework"})

        entry = Map.fetch!(next.running, issue_id)
        assert entry.issue.state == "rework"
        assert get_in(entry, [:control, :status]) == :deactivated
        assert log =~ "issue comment reactivation deferred"

        # Remote workers cannot write their workspace logs from the
        # orchestrator host, so the durable operator alert belongs in the
        # central feed instead.
        log =
          :aiur
          |> Application.fetch_env!(:log_file)
          |> Path.dirname()
          |> Path.join("alerts.ndjson")
          |> File.read!()

        assert log =~ "\"name\":\"ticket.#{issue_identifier}.agent.review_feedback_delivery_deferred\""
        assert log =~ "\"needs_attention\":true"
        assert log =~ "\"severity\":\"warning\""
      after
        if previous_memory_issues do
          Application.put_env(:aiur, :memory_tracker_issues, previous_memory_issues)
        else
          Application.delete_env(:aiur, :memory_tracker_issues)
        end

        if previous_memory_recipient do
          Application.put_env(:aiur, :memory_tracker_recipient, previous_memory_recipient)
        else
          Application.delete_env(:aiur, :memory_tracker_recipient)
        end

        File.rm_rf(test_root)
      end
    end
  end
end
