defmodule Aiur.Orchestrator.MergedTicketReferenceTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  test "a Refs-only merge leaves the ticket state alone and comments with the PR" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [%{merged_pr("Refs #1570") | ticket_id: "1600"}] end,
        reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> false end,
        mark_reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> :ok end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn id, target, expected ->
          send(parent, {:transition, id, target, expected})
          :ok
        end,
        add_label_fun: fn id, label ->
          send(parent, {:label, id, label})
          :ok
        end,
        create_comment_fun: fn id, body ->
          send(parent, {:comment, id, body})
          :ok
        end,
        close_optimistic_ledger_fun: fn id, outcome, _at ->
          send(parent, {:ledger_closed, id, outcome})
          :ok
        end
      )

    assert_receive {:comment, "1570", body}, 1000
    assert body =~ "PR 1600 referencing this ticket merged"
    refute_receive {:label, _, _}, 100
    refute_receive {:transition, _, _, _}, 100
    assert issues == []
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1570", "owner/repo#1600"})
    refute_receive {:transition, "1570", "done", _}, 100
    refute_receive {:ledger_closed, "1570", :merged}, 100
  end

  test "a commit-message Refs link gets a comment and never writes ticket state" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()
    merge = %{merged_pr(nil) | ticket_id: "1600", commit_messages: ["Refs #1570"]}

    {_state, []} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merge] end,
        reference_merge_reconciled_fun: fn _, _ -> false end,
        mark_reference_merge_reconciled_fun: fn _, _ -> :ok end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _, _, _ -> flunk("reference merge must not change ticket state") end,
        create_comment_fun: fn id, body ->
          send(parent, {:comment, id, body})
          :ok
        end
      )

    assert_receive {:comment, "1570", body}, 1000
    assert body =~ "PR 1600 referencing this ticket merged"
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
