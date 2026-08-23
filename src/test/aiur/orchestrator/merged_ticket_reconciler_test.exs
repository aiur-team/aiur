defmodule Aiur.Orchestrator.MergedTicketReconcilerTest do
  use ExUnit.Case, async: true

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

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

    assert_receive {:transition, "1570", "done", "in-progress"}
    assert_receive {:resume_blockees, "1570"}
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}
    assert opts[:message] =~ "PR #1600"
    assert opts[:message] =~ "resumed 1 of 1 dependent agent(s)"
    assert issues == []
    assert state.running == %{}
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

    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}
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
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}
    assert opts[:message] =~ "no dependent agents were waiting on it"
    assert opts[:severity] == "info"
    refute opts[:needs_attention]
    assert opts[:reason] =~ "best-effort"
    refute opts[:reason] =~ "develop"
    refute opts[:reason] =~ "atomic"
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
    assert_receive {:transition, "1570"}
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}

    reopened = %{issue | state: "Todo"}
    assert {^state, [^reopened]} = MergedTicketReconciler.reconcile(state, [reopened], opts)

    refute_receive {:transition, "1570"}
    refute_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", _opts}
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
    refute_receive {:transition, "1570"}
    refute_receive {:alert, _topic, _opts}
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
        update_issue_state_fun: fn _identifier, _state_name, _expected_state -> {:error, :forbidden} end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:ok, []} end
      )

    assert result.running == state.running
    assert issues == [blocker]

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}
    assert opts[:needs_attention]
    assert opts[:message] =~ "could not reconcile ticket 1570"
    assert opts[:reason] =~ "PR #1600"
    assert opts[:reason] =~ "1 dependent agent(s) remain paused"
  end

  test "a failing transition with no dependents still raises an attention, once" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "Todo"}
    parent = self()

    opts =
      [
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn _identifier, _state_name, _expected -> {:error, :forbidden} end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end
      ] ++ no_open_pull_requests()

    {state, [^issue]} = MergedTicketReconciler.reconcile(%State{}, [issue], opts)

    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", alert_opts}
    assert alert_opts[:needs_attention]
    assert alert_opts[:reason] =~ "will keep being retried"

    {_state, [^issue]} = MergedTicketReconciler.reconcile(state, [issue], opts)
    refute_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", _opts}
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

    assert_receive {:merger_checked, "drive-by-bot"}
  end

  test "a merged PR does not close a ticket whose other open PR carries CHANGES_REQUESTED; it routes to rework" do
    # The acceptance regression: ticket #2307 had two open PRs; the first merged
    # and the reconciler stamped `done`, abandoning the second PR's
    # CHANGES_REQUESTED findings. The remaining PR must land the ticket in
    # `rework` — asserting merely "not done" would pass if the reconciler wrote
    # nothing at all, which is a different bug with the same symptom.
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {_state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier ->
          {:ok,
           [
             %{
               "number" => 2318,
               "head" => %{"ref" => "aiur/2307-agents-run-stale-budget"},
               "review_decision" => "CHANGES_REQUESTED"
             }
           ]}
        end
      )

    # The specific label, not a mere "not done".
    assert_receive {:transition, "1570", "rework", "in-progress"}
    refute_receive {:transition, "1570", "done", _expected}
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}
    assert opts[:message] =~ "rework instead of done"
  end

  test "a merged PR routes a ticket to human-review when its remaining open PR merely awaits review" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {_state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier ->
          {:ok,
           [
             %{
               "number" => 2318,
               "head" => %{"ref" => "aiur/2307-agents-run-stale-budget"},
               "review_decision" => "APPROVED"
             }
           ]}
        end
      )

    assert_receive {:transition, "1570", "human-review", "in-progress"}
    refute_receive {:transition, "1570", "done", _expected}
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}
    assert opts[:message] =~ "human-review instead of done"
  end

  test "a failed open-PR lookup never closes a ticket" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    parent = self()

    {_state, issues} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        update_issue_state_fun: fn identifier, state_name, expected_state ->
          send(parent, {:transition, identifier, state_name, expected_state})
          :ok
        end,
        resume_blockees_fun: fn state, _identifier -> state end,
        emit_alert_fun: fn topic, opts -> send(parent, {:alert, topic, opts}) end,
        open_pull_requests_fun: fn _identifier -> {:error, :github_api_status} end
      )

    refute_receive {:transition, "1570", _state_name, _expected}
    assert issues == [issue]
    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}
    assert opts[:needs_attention]
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
