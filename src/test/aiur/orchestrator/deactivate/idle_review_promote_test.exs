defmodule Aiur.Orchestrator.Deactivate.IdleReviewPromoteTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator

  import Aiur.OrchestratorDeactivateSupport

  describe "idle review comment auto-promote to rework (no running entry) (#696)" do
    # The live #696 symptom was an `agent:human-review` ticket with no running
    # agent whose trusted reviewer comment was logged as
    # "issue comment ignored for idle issue". These drive the idle path —
    # `handle_info({:event, ...})` with an empty `running` map →
    # `maybe_transition_idle_issue_to_rework` — across the three acceptance
    # scenarios: trusted promotes to rework; untrusted and the bot's own
    # comment do not (no self-trigger loop).
    setup do
      previous_recipient = Application.get_env(:aiur, :memory_tracker_recipient)
      previous_issues = Application.get_env(:aiur, :memory_tracker_issues)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        tracker_active_states: ["todo", "in-progress", "rework", "merging"],
        tracker_terminal_states: ["done", "cancelled", "canceled"]
      )

      Application.put_env(:aiur, :memory_tracker_recipient, self())

      on_exit(fn ->
        restore_application_env(:memory_tracker_recipient, previous_recipient)
        restore_application_env(:memory_tracker_issues, previous_issues)
      end)

      :ok
    end

    test "a trusted comment on a human-review ticket transitions it to rework" do
      issue_identifier = "70"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR up for review",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.issue.commented",
             author_trusted?: true,
             comment: %{body: "Please rename the helper to decode_frame/1"}
           }},
          empty_orchestrator_state()
        )

      receive_barrier({:memory_tracker_state_update, ^issue_identifier, "rework"})
    end

    test "a trusted comment on a merging ticket transitions it to rework" do
      # #696's merging extension: a last-minute "actually, change this" comment
      # during merge must promote the idle ticket too, not only human-review.
      issue_identifier = "73"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "merging",
          title: "PR mid-merge",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.issue.commented",
             author_trusted?: true,
             comment: %{body: "hold the merge — please revert the rename"}
           }},
          empty_orchestrator_state()
        )

      receive_barrier({:memory_tracker_state_update, ^issue_identifier, "rework"})
    end

    test "an untrusted comment is ignored (no transition)" do
      issue_identifier = "71"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{id: issue_identifier, identifier: issue_identifier, state: "human-review"}
      ])

      log =
        capture_log(fn ->
          {:noreply, _next} =
            Orchestrator.handle_info(
              {:event,
               %{
                 topic: "ticket.#{issue_identifier}.issue.commented",
                 author_trusted?: false,
                 comment: %{body: "drive-by comment from a stranger"}
               }},
              empty_orchestrator_state()
            )
        end)

      # Scope the refute to the issue under test (matching the positive cases'
      # `^issue_identifier`): a stray `rework` transition for an unrelated issue
      # leaked from another test in the suite must not be read as this idle
      # untrusted comment self-triggering a promotion (#708 CI flake).
      # handle_info/2 returns after the transition gate has completed.
      refute_received {:memory_tracker_state_update, ^issue_identifier, "rework"}
      assert log =~ "issue comment ignored for idle issue"
      assert log =~ ":untrusted_author"
    end

    test "the bot's own '[codex] review passed' comment does not self-trigger rework" do
      issue_identifier = "72"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{id: issue_identifier, identifier: issue_identifier, state: "human-review"}
      ])

      log =
        capture_log(fn ->
          {:noreply, _next} =
            Orchestrator.handle_info(
              {:event,
               %{
                 topic: "ticket.#{issue_identifier}.issue.commented",
                 author_trusted?: true,
                 comment: %{body: "[codex] Review passed for commit abc123"}
               }},
              empty_orchestrator_state()
            )
        end)

      # Scope to the issue under test so a stray `rework` for an unrelated issue
      # (leaked from another suite test) can't masquerade as a self-trigger.
      # handle_info/2 returns after the transition gate has completed.
      refute_received {:memory_tracker_state_update, ^issue_identifier, "rework"}
      assert log =~ ":benign_review_pass_comment"
    end

    test "a trusted CHANGES_REQUESTED review wakes a fully-idle human-review ticket into rework" do
      # Regression coverage for #1389: a CHANGES_REQUESTED review posted while the
      # agent entry is fully torn down (no running entry) must still transition to
      # rework. This is the exact shape of the four reproductions from BO #1363.
      issue_identifier = "76"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_identifier,
          identifier: issue_identifier,
          state: "human-review",
          title: "PR awaiting review",
          description: "",
          labels: []
        }
      ])

      {:noreply, _next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.pr.review_comment",
             author_trusted?: true,
             comment: %{
               "state" => "CHANGES_REQUESTED",
               "body" => "Please rename the helper before merge",
               "user" => %{"login" => "its-everdred"},
               "submitted_at" => "2026-07-30T16:24:00Z"
             }
           }},
          empty_orchestrator_state()
        )

      receive_barrier({:memory_tracker_state_update, ^issue_identifier, "rework"})
    end

    test "a trusted CHANGES_REQUESTED review wakes a :deactivated human-review entry into rework" do
      # Regression coverage for #1389: a review comment must also reactivate an
      # entry still present in state.running but marked :deactivated (human-review
      # paused). This path goes through reactivate_if_deactivated.
      issue_identifier = "77"
      issue_id = "issue-#{issue_identifier}"

      Application.put_env(:aiur, :memory_tracker_issues, [
        %Issue{
          id: issue_id,
          identifier: issue_identifier,
          state: "rework",
          title: "PR changes requested",
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

      {:noreply, next} =
        Orchestrator.handle_info(
          {:event,
           %{
             topic: "ticket.#{issue_identifier}.pr.review_comment",
             author_trusted?: true,
             comment: %{
               "state" => "CHANGES_REQUESTED",
               "body" => "Please rename the helper before merge",
               "user" => %{"login" => "its-everdred"},
               "submitted_at" => "2026-07-30T16:24:00Z"
             }
           }},
          state
        )

      receive_barrier({:memory_tracker_state_update, ^issue_id, "rework"})
      entry = Map.fetch!(next.running, issue_id)
      refute get_in(entry, [:control, :status]) == :deactivated
    end
  end
end
