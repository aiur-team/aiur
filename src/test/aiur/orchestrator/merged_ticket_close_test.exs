defmodule Aiur.Orchestrator.MergedTicketCloseTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State, TrackerTasks}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  # The reconciler consults the ticket's other open PRs before deciding `done`,
  # so every reconcile must say what it sees: no open PRs keeps the legacy
  # one-PR-per-ticket terminal path.
  defp no_open_pull_requests, do: [open_pull_requests_fun: fn _identifier -> {:ok, []} end]

  test "closes an active issue linked by a merged PR body, resumes dependents, and emits a visible alert" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    blockee = %Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}
    parent = self()

    state = blocked_state(issue, blockee)

    {state, issues} =
      MergedTicketReconciler.reconcile(state, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, identifier ->
          send(parent, {:resume_blockees, identifier})
          %{state | running: %{}}
        end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert_receive {:transition, "1570", "done", "in-progress"}, 1000
    assert_receive {:resume_blockees, "1570"}, 1000
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}, 1000
    assert opts[:message] =~ "PR #1600"
    assert opts[:message] =~ "resumed 1 of 1 dependent agent(s)"
    assert issues == []
    assert state.running == %{}
  end

  test "a Refs-only merge keeps the ticket open, moves it to triage, and comments with the PR" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [%{merged_pr("Refs #1570") | ticket_id: "1570"}] end,
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

    assert_receive {:label, "1570", "needs-triage"}, 1000
    assert_receive {:transition, "1570", "human-review", "in-progress"}, 1000
    assert_receive {:comment, "1570", body}, 1000
    assert body =~ "PR #1600"
    assert body =~ "https://github.com/owner/repo/pull/1600"
    assert issues == []
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1570", "owner/repo#1600"})
    refute_receive {:transition, "1570", "done", _}, 100
    refute_receive {:ledger_closed, "1570", :merged}, 100
  end

  test "does not triage a different ticket referenced by this PR" do
    issue = %Issue{id: "issue-5162", identifier: "5162", state: "human-review"}
    parent = self()
    merge = %{merged_pr("Refs #5162") | ticket_id: "5254"}

    {state, [^issue]} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merge] end,
        reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> false end,
        mark_reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> :ok end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn id, target, _expected ->
          send(parent, {:transition, id, target})
          :ok
        end,
        add_label_fun: fn id, label ->
          send(parent, {:label, id, label})
          :ok
        end,
        create_comment_fun: fn id, body ->
          send(parent, {:comment, id, body})
          :ok
        end
      )

    refute MapSet.member?(state.merged_ticket_reconciliations, {"5162", merge.id})
    refute_receive {:transition, _, _}, 100
    refute_receive {:label, _, _}, 100
    refute_receive {:comment, _, _}, 100
  end

  test "a leading Part of reference parks the merged ticket for triage" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [%{merged_pr("Part of #1570") | ticket_id: "1570"}] end,
        reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> false end,
        mark_reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> :ok end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn id, target, _expected ->
          send(parent, {:transition, id, target})
          :ok
        end,
        add_label_fun: fn id, label ->
          send(parent, {:label, id, label})
          :ok
        end,
        create_comment_fun: fn id, body ->
          send(parent, {:comment, id, body})
          :ok
        end
      )

    assert_receive {:label, "1570", "needs-triage"}, 1000
    assert_receive {:transition, "1570", "human-review"}, 1000
    assert_receive {:comment, "1570", body}, 1000
    assert body =~ "PR #1600"
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1570", "owner/repo#1600"})
  end

  test "a closed Refs ticket still receives the authoritative closed-ticket repair" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "Closed", state_labels: []}
    parent = self()
    merge = %{merged_pr("Refs #1570") | ticket_id: "1570"}

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn id, target, expected ->
          send(parent, {:transition, id, target, expected})
          :ok
        end,
        resume_blockees_fun: fn current, _id -> current end,
        emit_alert_fun: fn topic, _opts -> send(parent, {:alert, topic}) end
      )

    assert_receive {:transition, "1570", "done", :none}, 1000
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled"}, 1000
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1570", merge.id})
  end

  test "alerts when the owner task cannot write reference triage" do
    parent = self()
    owner_name = String.to_atom("merged_ticket_owner_#{System.unique_integer([:positive])}")

    task =
      Task.async(fn ->
        Process.register(self(), owner_name)
        state = %State{snapshot_key: owner_name}

        pending =
          MergedTicketReconciler.reconcile(state, [%Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}],
            recent_merges_fun: fn -> [%{merged_pr("Refs #1570") | ticket_id: "1570"}] end,
            reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> false end,
            mark_reference_merge_reconciled_fun: fn _merge_id, _ticket_id -> :ok end,
            now_fun: fn -> @now end,
            update_issue_state_fun: fn _, _, _ -> {:error, :forbidden} end,
            add_label_fun: fn _, _ -> :ok end,
            emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
          )
          |> elem(0)

        [{ref, job}] = Map.to_list(pending.tracker_tasks)
        result = Task.await(job.task)
        {:handled, transitioned} = TrackerTasks.result(pending, ref, result)
        [{write_ref, write_job}] = Map.to_list(transitioned.tracker_tasks)
        write_result = Task.await(write_job.task)
        {:handled, final} = TrackerTasks.result(transitioned, write_ref, write_result)
        Process.unregister(owner_name)
        final
      end)

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}, 1000
    assert opts[:reason] =~ "forbidden"
    assert %State{} = Task.await(task)
  end

  test "reports the dependents actually resumed rather than the count sampled beforehand" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    blockee = %Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}
    parent = self()

    {_state, _issues} =
      MergedTicketReconciler.reconcile(blocked_state(issue, blockee), [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _identifier, _state_name, _expected -> :ok end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}, 1000
    assert opts[:message] =~ "resumed 0 of 1 dependent agent(s)"
    refute opts[:reason] =~ "atomic"
  end

  test "announces a reconciliation that has no dependents at all" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "Todo"}
    parent = self()

    {_state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _identifier, _state_name, _expected -> :ok end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}, 1000
    assert opts[:message] =~ "no dependent agents were waiting on it"
    assert opts[:severity] == "info"
    refute opts[:needs_attention]
    assert opts[:reason] =~ "best-effort"
    refute opts[:reason] =~ "develop"
    refute opts[:reason] =~ "atomic"
  end

  test "repairs a closed zero-label ticket from its merged branch identity" do
    issue = %Issue{id: "1570", identifier: "1570", state: "Closed", state_labels: []}
    merge = %{merged_pr(nil) | ticket_id: "1570"}
    parent = self()

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier ->
          flunk("a closed zero-label repair must not inspect open PRs")
        end
      )

    assert_receive {:transition, "1570", "done", :none}, 1000
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}, 1000
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1570", merge.id})
  end

  test "repairs a closed branch ticket absent from the open candidate list" do
    merge = %{merged_pr(nil) | ticket_id: "1571", merged_by: "its-everdred"}
    parent = self()

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [],
        recent_merges_fun: fn -> [merge] end,
        now_fun: fn -> @now end,
        fetch_issue_states_fun: fn ["1571"], cache ->
          {:ok, [%Issue{id: "1571", identifier: "1571", state: "Closed", state_labels: []}], cache}
        end,
        update_issue_state_fun: fn id, target, expected ->
          send(parent, {:transition, id, target, expected})
          :ok
        end,
        emit_alert_fun: fn topic, _opts -> send(parent, {:alert, topic}) end
      )

    assert_receive {:transition, "1571", "done", :none}, 1000
    assert_receive {:alert, "ticket.1571.dependency.merged_blocker_reconciled"}, 1000
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1571", merge.id})
  end

  test "a healthy closed merge ticket is conditionally checked once" do
    merge = %{merged_pr(nil) | ticket_id: "1572", merged_by: "its-everdred"}
    parent = self()

    fetch = fn ["1572"], cache ->
      send(parent, :fetched)
      issue = %Issue{id: "1572", identifier: "1572", state: "Closed", state_labels: ["agent:done"]}
      {:ok, [issue], Map.put(cache, "1572", %{etag: "tag", issue: issue})}
    end

    {state, []} =
      MergedTicketReconciler.reconcile(%State{}, [],
        recent_merges_fun: fn -> [%{merge | summary: "Closes #1572"}] end,
        now_fun: fn -> @now end,
        fetch_issue_states_fun: fetch
      )

    assert_receive :fetched, 1000
    assert MapSet.member?(state.merged_ticket_reconciliations, {"1572", merge.id})

    MergedTicketReconciler.reconcile(state, [],
      recent_merges_fun: fn -> [merge] end,
      now_fun: fn -> @now end,
      fetch_issue_states_fun: fn _, _ -> flunk("healthy merge ticket was fetched twice") end
    )

    refute_receive :fetched, 50
  end

  test "a merge that already closed a ticket cannot close it again after a reopen" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()
    merges = [merged_pr("Closes #1570")]

    opts =
      [
        recent_merges_fun: fn -> merges end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, _state_name, _expected ->
          send(parent, {:transition, identifier})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      ] ++ no_open_pull_requests()

    {state, []} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)
    assert_receive {:transition, "1570"}, 1000
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}, 1000

    reopened = %{issue | state: "Todo"}
    assert {^state, [^reopened]} = MergedTicketReconciler.reconcile(state, [reopened], opts)

    refute_receive {:transition, "1570"}, 100
    refute_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}, 100
  end

  test "a merge older than the staleness window never closes a ticket" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "Todo"}
    parent = self()

    {state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> DateTime.add(@merged_at, 25 * 60 * 60, :second) end,
        update_issue_state_fun: fn identifier, _state_name, _expected ->
          send(parent, {:transition, identifier})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert issues == [issue]
    assert state == %State{}
    refute_receive {:transition, "1570"}, 100
    refute_receive {:alert, _topic, _opts}, 100
  end

  test "keeps the ticket and raises an attention when a merged blocker cannot be reconciled" do
    blocker = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    blockee = %Issue{id: "issue-1571", identifier: "1571", state: "in-progress"}

    state = blocked_state(blocker, blockee)
    parent = self()

    {result, issues} =
      MergedTicketReconciler.reconcile(state, [blocker],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _identifier, _state_name, _expected_state ->
          {:error, :forbidden}
        end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert result.running == state.running
    assert issues == [blocker]

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts},
                   1000

    assert opts[:needs_attention]
    assert opts[:message] =~ "could not reconcile ticket 1570"
    assert opts[:reason] =~ "PR #1600"
    assert opts[:reason] =~ "1 dependent agent(s) remain paused"
  end

  test "a failing transition with no dependents still raises an attention, once" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    opts =
      [
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _identifier, _state_name, _expected -> {:error, :forbidden} end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      ] ++ no_open_pull_requests()

    {state, [^issue]} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", alert_opts},
                   1000

    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "will keep being retried"

    {_state, [^issue]} = MergedTicketReconciler.reconcile(state, [issue], opts)

    refute_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", _opts},
                   100
  end

  test "audits the merger recorded on the merge instead of trusting every login" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    merge = %{merged_pr("Closes #1570") | merged_by: "drive-by-bot"}

    MergedTicketReconciler.reconcile(%State{}, [issue],
      recent_merges_fun: fn -> [merge] end,
      now_fun: fn -> @now end,
      update_issue_state_fun: fn _identifier, _state_name, _expected -> :ok end,
      resume_blockees_fun: fn state, _identifier -> state end,
      emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
      open_pull_requests_fun: fn _identifier -> {:ok, []} end,
      merger_allowed_fun: fn login ->
        send(parent, {:merger_checked, login})
        false
      end
    )

    assert_receive {:merger_checked, "drive-by-bot"}, 1000
  end

  defp blocked_state(blocker, blockee) do
    %State{
      running: %{
        blockee.id => %{
          identifier: blockee.identifier,
          issue: blockee,
          paused_reason: :blocker_dependency,
          blocker_pause: %{blocker_identifier: blocker.identifier}
        }
      }
    }
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
