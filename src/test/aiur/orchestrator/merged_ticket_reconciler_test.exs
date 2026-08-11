defmodule Aiur.Orchestrator.MergedTicketReconcilerTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]

  test "closes an active issue linked by a merged PR body, resumes dependents, and emits a visible alert" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    blockee = %Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}
    parent = self()

    state = %State{
      running: %{
        blockee.id => %{
          identifier: blockee.identifier,
          issue: blockee,
          paused_reason: :blocker_dependency,
          blocker_pause: %{blocker_identifier: issue.identifier}
        }
      }
    }

    {state, issues} =
      MergedTicketReconciler.reconcile(state, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, identifier ->
          send(parent, {:resume_blockees, identifier})
          state
        end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert_receive {:transition, "1570", "done", "in-progress"}
    assert_receive {:resume_blockees, "1570"}
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}
    assert opts[:message] =~ "PR #1600"
    assert opts[:message] =~ "1 dependent agent(s)"
    assert issues == []

    assert state.running == %{
             blockee.id => %{
               identifier: blockee.identifier,
               issue: blockee,
               paused_reason: :blocker_dependency,
               blocker_pause: %{blocker_identifier: issue.identifier}
             }
           }
  end

  test "keeps the ticket and raises an attention when a merged blocker cannot be reconciled" do
    blocker = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    blockee = %Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}

    state = %State{
      running: %{
        blockee.id => %{
          identifier: blockee.identifier,
          issue: blockee,
          paused_reason: :blocker_dependency,
          blocker_pause: %{blocker_identifier: blocker.identifier}
        }
      }
    }

    parent = self()

    {result, issues} =
      MergedTicketReconciler.reconcile(state, [blocker],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        update_issue_state_fun: fn _identifier, _state_name, _expected_state -> {:error, :forbidden} end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      )

    assert result == state
    assert issues == [blocker]

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}
    assert opts[:needs_attention]
    assert opts[:message] =~ "could not reconcile ticket 1570"
    assert opts[:reason] =~ "PR #1600"
    assert opts[:reason] =~ "1 dependent agent(s) remain paused"
  end

  defp merged_pr(summary) do
    %RecentMerge{
      id: "owner/repo#1600",
      repository: "owner/repo",
      number: 1600,
      url: "https://github.com/owner/repo/pull/1600",
      summary: summary,
      merged_at: @merged_at,
      observation_source: :github_events,
      backfilled?: false,
      live_observed?: true,
      first_observed_at: @merged_at,
      last_observed_at: @merged_at,
      content_hash: "hash"
    }
  end
end
