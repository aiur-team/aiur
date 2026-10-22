defmodule Aiur.Orchestrator.MergedTicketOpenPRTest.Tracker do
  def start(id, labels, park? \\ false) do
    {:ok, pid} = Agent.start_link(fn -> %{labels: labels, park?: park?, result: nil} end)
    :persistent_term.put({__MODULE__, id}, pid)
    pid
  end

  def stop(id, pid) do
    :persistent_term.erase({__MODULE__, id})
    if Process.alive?(pid), do: Agent.stop(pid)
  end

  def labels(id), do: Agent.get(fetch(id), & &1.labels)
  def result(id), do: Agent.get(fetch(id), & &1.result)

  def update_issue_state(id, target, opts) do
    Agent.get_and_update(fetch(id), fn state ->
      labels = if state.park?, do: ["needs-triage"], else: state.labels
      refused = Enum.map(Keyword.get(opts, :refuse_labels, []), &String.downcase/1)

      if Enum.any?(labels, &(String.downcase(&1) in refused)) do
        result = {:error, {:operator_hold, "needs-triage"}}
        {result, %{state | labels: labels, result: result}}
      else
        next_labels = ["agent:#{target}" | Enum.reject(labels, &String.starts_with?(&1, "agent:"))]
        {:ok, %{state | labels: next_labels, park?: false, result: :ok}}
      end
    end)
  end

  def update_issue_state(_id, _target), do: {:error, :expected_state_unsupported}

  defp fetch(id), do: :persistent_term.get({__MODULE__, id})
end

defmodule Aiur.Orchestrator.MergedTicketOpenPRTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aiur.{Issue, RecentMerge}
  alias Aiur.Orchestrator.MergedTicketOpenPRTest.Tracker
  alias Aiur.Orchestrator.{MergedTicketReconciler, State}

  @merged_at ~U[2026-08-10 00:00:00Z]
  @now ~U[2026-08-10 01:00:00Z]

  test "the reconciler preserves an operator park added before the human-review write" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    tracker = Tracker.start("1570", ["agent:in-progress"], true)
    on_exit(fn -> Tracker.stop("1570", tracker) end)

    {_state, [^issue]} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [merged_pr("Closes #1570")] end,
        now_fun: fn -> @now end,
        tracker: Tracker,
        open_pull_requests_fun: fn _ ->
          {:ok, [%{"number" => 1571, "head" => %{"ref" => "aiur/1570-other"}}]}
        end,
        unresolved_threads_fetcher: fn _ -> {:ok, []} end
      )

    assert Tracker.result("1570") == {:error, {:operator_hold, "needs-triage"}}
    assert Tracker.labels("1570") == ["needs-triage"]
  end

  test "a reference-only merge refuses an existing operator park before adding its marker" do
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "in-progress"}
    tracker = Tracker.start("1570", ["agent:in-progress"], true)
    on_exit(fn -> Tracker.stop("1570", tracker) end)

    {_state, [^issue]} =
      MergedTicketReconciler.reconcile(%State{}, [issue],
        recent_merges_fun: fn -> [%{merged_pr("Refs #1570") | ticket_id: "1570"}] end,
        now_fun: fn -> @now end,
        tracker: Tracker,
        add_label_fun: fn _identifier, _label -> flunk("a parked ticket must not receive a merge marker") end,
        emit_alert_fun: fn _topic, _opts -> :ok end
      )

    assert Tracker.result("1570") == {:error, {:operator_hold, "needs-triage"}}
    assert Tracker.labels("1570") == ["needs-triage"]
  end

  test "a merged PR routes a ticket to rework when its remaining open PR has unresolved review threads" do
    # The acceptance regression: ticket #2307 had two open PRs; the first merged
    # and the reconciler stamped `done`, abandoning the second PR's
    # CHANGES_REQUESTED findings. The remaining PR's *unresolved review threads*
    # must land the ticket in `rework` — asserting merely "not done" would pass
    # if the reconciler wrote nothing at all, which is a different bug with the
    # same symptom. This is also the #2450 control: genuinely unresolved threads
    # must still route to rework, or "does not route" would be indistinguishable
    # from "routing disabled".
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
               "head" => %{"sha" => "head-2318", "ref" => "aiur/2307-agents-run-stale-budget"},
               "review_decision" => "CHANGES_REQUESTED"
             }
           ]}
        end,
        unresolved_threads_fetcher: fn _pr -> {:ok, [%{"id" => "thread-1"}]} end
      )

    # The specific label, not a mere "not done".
    assert_receive {:transition, "1570", "rework", "in-progress"}, 1000
    refute_receive {:transition, "1570", "done", _expected}, 100
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}, 1000
    assert opts[:message] =~ "rework instead of done"
  end

  test "a CHANGES_REQUESTED remaining PR with zero unresolved review threads does not route the merged ticket to rework" do
    # #2450 acceptance: `reviewDecision` is sticky — it stays CHANGES_REQUESTED
    # after the requested changes are pushed, until a reviewer submits a new
    # review. Routing on the verdict alone re-flips a finished ticket to rework
    # on every poll (#2309, narrower path). The actionable signal is unresolved
    # review threads: a PR whose threads are all resolved is merely awaiting a
    # fresh review, so the merged ticket must keep its state rather than degrade
    # to rework.
    issue = %Issue{id: "issue-1570", identifier: "1570", state: "human-review"}
    parent = self()

    log =
      capture_log(fn ->
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
            end,
            unresolved_threads_fetcher: fn _pr -> {:ok, []} end
          )

        assert issues == []
      end)

    # The ticket is not routed to rework: it keeps its human-review state.
    refute_receive {:transition, "1570", "rework", _expected}, 100
    assert_receive {:transition, "1570", "human-review", "human-review"}, 1000
    refute_receive {:transition, "1570", "done", _expected}, 100
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}, 1000
    assert opts[:message] =~ "human-review instead of done"

    # The skip is a *named* reason, not a silent "not rework": the gate read the
    # thread state and deliberately refused rework because the threads are clear.
    assert log =~ ":no_unresolved_review_threads"
  end

  test "a merged PR routes a ticket with an approved remaining PR to ci-wait" do
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
               "head" => %{"sha" => "head-2318", "ref" => "aiur/2307-agents-run-stale-budget"},
               "review_decision" => "APPROVED"
             }
           ]}
        end,
        reviews_fetcher: fn 2318 -> {:ok, []} end,
        pull_request_approval_fetcher: fn 2318 -> {:ok, {"head-2318", "head-2318"}} end
      )

    assert_receive {:transition, "1570", "ci-wait", "in-progress"}, 1000
    refute_receive {:transition, "1570", "done", _expected}, 100
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}, 1000
    assert opts[:message] =~ "ci-wait instead of done"
  end

  test "a merged PR waits for review when only one of two remaining PRs is approved" do
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
        emit_alert_fun: fn _topic, _opts -> :ok end,
        open_pull_requests_fun: fn _identifier ->
          {:ok,
           [
             %{"number" => 2318, "head" => %{"sha" => "approved-head", "ref" => "aiur/1570-approved"}, "review_decision" => "APPROVED"},
             %{"number" => 2319, "head" => %{"sha" => "unreviewed-head", "ref" => "aiur/1570-unreviewed"}}
           ]}
        end,
        reviews_fetcher: fn _number -> {:ok, []} end,
        pull_request_approval_fetcher: fn
          2318 -> {:ok, {"approved-head", "approved-head"}}
          2319 -> {:ok, {"unreviewed-head", nil}}
        end
      )

    assert_receive {:transition, "1570", "human-review", "in-progress"}, 1000
    refute_receive {:transition, "1570", "ci-wait", _expected}, 100
    assert issues == []
  end

  test "a stale draft left open after a merge does not pin the ticket out of done" do
    # The mirror-image of the #2307 defect: a dead draft from a superseded
    # attempt left open forever must not keep a ticket out of `done`. A draft
    # with no update within the staleness window is treated as abandoned and
    # does not block the terminal transition — the specific label `done` is
    # asserted, not merely "not rework".
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
               "draft" => true,
               "updated_at" => "2026-07-30T00:00:00Z"
             }
           ]}
        end
      )

    assert_receive {:transition, "1570", "done", "in-progress"}, 1000
    refute_receive {:transition, "1570", "rework", _expected}, 100
    refute_receive {:transition, "1570", "human-review", _expected}, 100
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_blocker_reconciled", opts}, 1000
    assert opts[:message] =~ "closed ticket 1570"
  end

  test "a draft with recent activity still blocks done and routes to human-review" do
    # Only drafts with no update within the staleness window are treated as
    # abandoned. A draft updated recently is live work: it must still block the
    # terminal transition so the ticket's remaining PR is not abandoned.
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
               "draft" => true,
               "updated_at" => "2026-08-09T23:00:00Z"
             }
           ]}
        end
      )

    assert_receive {:transition, "1570", "human-review", "in-progress"}, 1000
    refute_receive {:transition, "1570", "done", _expected}, 100
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}, 1000
    assert opts[:message] =~ "human-review instead of done"
  end

  test "a stale non-draft open PR still blocks done" do
    # The draft requirement matters: a stale PR that was actually submitted for
    # review is still awaiting that review, so it must keep blocking the
    # terminal transition rather than being dismissed alongside abandoned
    # drafts.
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
               "draft" => false,
               "updated_at" => "2026-07-30T00:00:00Z",
               "review_decision" => "APPROVED"
             }
           ]}
        end
      )

    assert_receive {:transition, "1570", "human-review", "in-progress"}, 1000
    refute_receive {:transition, "1570", "done", _expected}, 100
    assert issues == []
    assert_receive {:alert, "ticket.1570.dependency.merged_pr_remaining_open", opts}, 1000
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

    refute_receive {:transition, "1570", _state_name, _expected}, 100
    assert issues == [issue]
    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}, 1000
    assert opts[:needs_attention]
  end

  test "an open-PR listing in an unexpected shape never closes a ticket" do
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
        open_pull_requests_fun: fn _identifier -> {:ok, %{"unexpected" => "shape"}} end
      )

    refute_receive {:transition, "1570", _state_name, _expected}, 100
    assert issues == [issue]
    assert_receive {:alert, "ticket.1570.agent.attention.merged_pr_reconciliation_failed", opts}, 1000
    assert opts[:needs_attention]
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
