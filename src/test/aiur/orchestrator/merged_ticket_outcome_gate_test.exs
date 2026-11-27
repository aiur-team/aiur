defmodule Aiur.Orchestrator.MergedTicketOutcomeGateTest do
  use Aiur.TestSupport

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{DispatchPolicy, MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  test "creator outcome can remain pending after merge without blocking dependents or dispatch" do
    issue = %Issue{
      id: "issue-8129",
      identifier: "8129",
      state: "in-progress",
      labels: ["creator-facing"]
    }

    parent = self()

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #8129")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, _expected_state ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        outcome_decisions_fun: fn ->
          [%{ticket: %{identifier: "8129"}, decision_status: :open}]
        end,
        post_deploy_checklist_status_fun: fn -> :ok end,
        post_deploy_checks_fun: fn -> [] end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert_receive {:transition, "8129", merged_state}, 1000
    assert merged_state == "done"
    assert MapSet.member?(state.merged_ticket_reconciliations, {"8129", "owner/repo#1600"})

    active = MapSet.new(["todo"])
    terminal = MapSet.new(["done"])
    blocked_tickets = MapSet.new(["repo#8129"])
    merged = %Issue{id: "issue-8129", identifier: "repo#8129", title: "merged", state: "done"}

    assert {:skip, :terminal_state} =
             DispatchPolicy.dispatch_candidate_decision(
               merged,
               %State{},
               active,
               terminal,
               blocked_tickets
             )

    dependent = %Issue{
      id: "issue-8134",
      identifier: "repo#8134",
      title: "dependent",
      state: "todo",
      blocked_by: [%{id: issue.id, identifier: "repo#8129", state: "done"}]
    }

    assert :dispatch =
             DispatchPolicy.dispatch_candidate_decision(
               dependent,
               %State{},
               active,
               terminal,
               blocked_tickets
             )

    outcome_pending_running = %{
      "8129" => %{issue: %{merged | state: merged_state}, control_status: :working}
    }

    assert DispatchPolicy.running_issue_count_for_state(outcome_pending_running, "in-progress") == 0
  end

  test "epic merge remains open when a linked child is not closed or a follow-up is untriaged" do
    issue = %Issue{
      id: "issue-8130",
      identifier: "8130",
      state: "in-progress",
      labels: ["epic"],
      description: "Children: #8131\nFollow-ups: #8132"
    }

    parent = self()

    {_, [^issue]} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #8130")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, _expected_state ->
          send(parent, {:transition, identifier, state_name})
          :ok
        end,
        related_issue_fetcher: fn ["8131", "8132"] ->
          {:ok,
           [
             %Issue{identifier: "8131", state: "open", labels: ["agent:todo"]},
             %Issue{identifier: "8132", state: "open", labels: ["needs-triage"]}
           ], %{}}
        end,
        post_deploy_checklist_status_fun: fn -> :ok end,
        post_deploy_checks_fun: fn -> [] end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert_receive {:transition, "8130", "human-review"}, 1000
  end

  test "closed creator ticket remains done when the outcome is pending" do
    merge = %{merged_pr("Closes #8133") | ticket_id: "8133", merged_by: "its-everdred"}
    parent = self()

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> @now end,
        fetch_issue_states_fun: fn ["8133"], cache ->
          issue = %Issue{
            id: "8133",
            identifier: "8133",
            state: "Closed",
            state_labels: ["agent:done"],
            labels: ["creator-facing"]
          }

          {:ok, [issue], cache}
        end,
        update_issue_state_fun: fn id, target, expected ->
          send(parent, {:transition, id, target, expected})
          :ok
        end,
        outcome_decisions_fun: fn -> [] end,
        post_deploy_checklist_status_fun: fn -> :ok end,
        post_deploy_checks_fun: fn -> [] end
      )

    assert_receive {:transition, "8133", "done", :none}, 1000
    assert MapSet.member?(state.merged_ticket_reconciliations, {"8133", merge.id})
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
