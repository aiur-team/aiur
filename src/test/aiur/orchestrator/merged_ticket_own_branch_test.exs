defmodule Aiur.Orchestrator.MergedTicketOwnBranchTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  test "closes an active issue when its own branch PR merged without a closing keyword" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "human-review"}
    parent = self()

    {state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Implements the accepted work.")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert_receive {:transition, "1570", "done", "human-review"}, 1000
    assert issues == []
    assert state.merged_ticket_reconciliations == MapSet.new([{"1570", "owner/repo#1600"}])
  end

  defp merged_pr(summary) do
    %RecentMerge{
      id: "owner/repo#1600",
      repository: "owner/repo",
      number: 1600,
      url: "https://github.com/owner/repo/pull/1600",
      summary: summary,
      head_ref: "aiur/1570-accepted-work",
      ticket_id: "1570",
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
