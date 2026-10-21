defmodule Aiur.Orchestrator.NonClosingMergeRestartTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge, RecentMergeStore}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  test "a re-dispatched ticket is not triaged again after reconciler and store restart" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    merge = stored_merge("Refs #1570")
    dir = Aiur.TestSupport.tmp_root!("aiur-reference-triage")
    store_name = String.to_atom("reference_triage_store_#{System.unique_integer([:positive])}")
    {:ok, store} = GenServer.start(RecentMergeStore, [name: store_name, state_dir: dir], name: store_name)

    on_exit(fn ->
      Aiur.TestSupport.safe_stop(store_name)
      Aiur.TestCleanup.rm_rf!(dir)
    end)

    assert {:ok, %{status: :accepted}} = RecentMergeStore.upsert(merge, store)

    opts = [
      recent_merges_fun: fn -> [merge] end,
      now_fun: fn -> @now end,
      reference_merge_reconciled_fun: fn merge_id, ticket_id ->
        RecentMergeStore.ticket_reconciled?(merge_id, ticket_id, store_name)
      end,
      mark_reference_merge_reconciled_fun: fn merge_id, ticket_id ->
        RecentMergeStore.mark_ticket_reconciled(merge_id, ticket_id, store_name)
      end,
      update_issue_state_fun: fn _, _, _ -> :ok end,
      add_label_fun: fn _, _ -> :ok end,
      create_comment_fun: fn _, _ -> :ok end
    ]

    assert {_, []} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)
    assert RecentMergeStore.ticket_reconciled?(merge.id, issue.identifier, store)
    Aiur.TestSupport.safe_stop(store)

    {:ok, restarted_store} = RecentMergeStore.start_link(name: store_name, state_dir: dir)
    assert RecentMergeStore.ticket_reconciled?(merge.id, issue.identifier, restarted_store)

    assert {%State{}, [^issue]} =
             MergedTicketReconciler.reconcile(
               %State{},
               [issue],
               Keyword.merge(opts,
                 update_issue_state_fun: fn _, _, _ -> flunk("re-dispatched ticket must not be re-triaged") end,
                 add_label_fun: fn _, _ -> flunk("re-dispatched ticket must not be re-triaged") end,
                 create_comment_fun: fn _, _ -> flunk("re-dispatched ticket must not receive a duplicate comment") end
               )
             )
  end

  test "a parked ticket carrying the marker is not commented again" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "human-review", labels: ["needs-triage"]}
    merge = stored_merge("Refs #1570")

    assert {%State{}, [^issue]} =
             MergedTicketReconciler.reconcile(%State{}, [issue],
               recent_merges_fun: fn -> [merge] end,
               now_fun: fn -> @now end,
               reference_merge_reconciled_fun: fn _, _ -> false end,
               update_issue_state_fun: fn _, _, _ -> flunk("already triaged ticket must not transition again") end,
               add_label_fun: fn _, _ -> flunk("already triaged ticket must not be relabeled") end,
               create_comment_fun: fn _, _ -> flunk("already triaged ticket must not receive a duplicate comment") end
             )
  end

  test "a failed reconciliation lookup defers triage until the next successful read" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    merge = stored_merge("Refs #1570")
    {:ok, writes} = Agent.start_link(fn -> [] end)
    {:ok, lookups} = Agent.start_link(fn -> 0 end)

    lookup = fn _, _ ->
      case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
        0 -> raise "store lookup failed"
        1 -> false
        _ -> true
      end
    end

    opts = [
      recent_merges_fun: fn -> [merge] end,
      now_fun: fn -> @now end,
      reference_merge_reconciled_fun: lookup,
      mark_reference_merge_reconciled_fun: fn _, _ -> :ok end,
      update_issue_state_fun: fn _, _, _ -> Agent.update(writes, &[:state | &1]) end,
      add_label_fun: fn _, _ -> Agent.update(writes, &[:marker | &1]) end,
      create_comment_fun: fn _, _ -> Agent.update(writes, &[:comment | &1]) end
    ]

    assert {%State{}, [^issue]} =
             MergedTicketReconciler.reconcile(%State{}, [issue], opts)

    assert Agent.get(writes, & &1) == []

    assert {%State{}, []} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)
    assert Enum.sort(Agent.get(writes, & &1)) == [:comment, :marker, :state]

    assert {%State{}, [^issue]} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)
    assert Enum.sort(Agent.get(writes, & &1)) == [:comment, :marker, :state]

    Agent.stop(writes)
    Agent.stop(lookups)
  end

  defp stored_merge(summary) do
    event = %{
      "id" => "evt-reference-1600",
      "type" => "PullRequestEvent",
      "created_at" => DateTime.to_iso8601(@merged_at),
      "repo" => %{"name" => "owner/repo"},
      "payload" => %{
        "action" => "closed",
        "pull_request" => %{
          "number" => 1600,
          "merged" => true,
          "merged_at" => DateTime.to_iso8601(@merged_at),
          "html_url" => "https://github.com/owner/repo/pull/1600",
          "body" => summary,
          "head" => %{"ref" => "aiur/1570", "sha" => "head-1570"}
        }
      }
    }

    assert {:ok, merge} = RecentMerge.from_github_event(event, live?: true, run_id: "run-test", now: @merged_at)
    merge
  end
end
