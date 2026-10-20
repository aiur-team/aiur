defmodule Aiur.Orchestrator.UnreviewedReadyPrTest do
  use Aiur.TestSupport

  alias Aiur.Orchestrator.{ReadyForReviewTransitions, State}
  import Aiur.CiLifecycleTestSupport

  alias Aiur.PrReadyLedgerStore

  setup :ci_lifecycle_setup

  setup do
    previous = Application.get_env(:aiur, :pr_ready_ledger_path)
    root = Aiur.TestSupport.tmp_root!("unreviewed_ready_pr")
    path = Path.join(root, "ledger.json")
    Application.put_env(:aiur, :pr_ready_ledger_path, path)

    on_exit(fn ->
      restore_application_env(:pr_ready_ledger_path, previous)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  test "raises once after the age limit and repeats only after backoff" do
    ticket = "5105"
    pr = 77
    head = String.duplicate("a", 40)
    ready_at = 1_000
    observation = %{ticket: ticket, pr_number: pr, head_sha: head, draft?: false, ready_at_ms: ready_at}
    state = %State{pr_ready_ledger: %{{ticket, pr} => {:announced, head, ready_at, nil}}}
    ref = make_ref()
    test_pid = self()

    emitter = fn topic, opts ->
      send(test_pid, {:attention, ref, topic, opts})
      :ok
    end

    result = %{decision: :passed, review_decision: "REVIEW_REQUIRED", reviewed_head?: false}
    opts = [now_ms: ready_at + 10_000, age_limit_ms: 10_000, backoff_ms: 5_000, repo_fun: fn -> "owner/repo" end, alert_emitter: emitter]

    first = ReadyForReviewTransitions.re_raise_unreviewed(state, observation, result, opts)
    assert_received {:attention, ^ref, "ticket.5105.agent.attention.unreviewed_ready_pr", first_opts}
    assert first_opts[:message] =~ "PR #77"
    assert first_opts[:message] =~ head
    assert first_opts[:message] =~ "0.0 hours"
    assert first.pr_ready_ledger[{ticket, pr}] == {:announced, head, ready_at, ready_at + 15_000}
    assert PrReadyLedgerStore.load()[{ticket, pr}] == {:announced, head, ready_at, ready_at + 15_000}

    too_soon = ReadyForReviewTransitions.re_raise_unreviewed(first, observation, result, Keyword.put(opts, :now_ms, ready_at + 14_999))
    refute_received {:attention, ^ref, _, _}
    assert too_soon == first

    second = ReadyForReviewTransitions.re_raise_unreviewed(first, observation, result, Keyword.put(opts, :now_ms, ready_at + 15_000))
    assert_received {:attention, ^ref, "ticket.5105.agent.attention.unreviewed_ready_pr", _}
    assert second.pr_ready_ledger[{ticket, pr}] == {:announced, head, ready_at, ready_at + 20_000}
  end

  test "does not raise for draft, red or pending CI, reviewed, or a different head" do
    ticket = "5105"
    pr = 78
    head = String.duplicate("b", 40)
    ready_at = 1_000
    base = %{ticket: ticket, pr_number: pr, head_sha: head, draft?: false, ready_at_ms: ready_at}
    state = %State{pr_ready_ledger: %{{ticket, pr} => {:announced, head, ready_at, nil}}}
    test_pid = self()

    opts = [
      now_ms: 20_000,
      age_limit_ms: 10_000,
      repo_fun: fn -> "owner/repo" end,
      alert_emitter: fn _, _ ->
        send(test_pid, :unexpected)
        :ok
      end
    ]

    for {observation, result} <- [
          {Map.put(base, :draft?, true), %{decision: :passed, review_decision: "REVIEW_REQUIRED", reviewed_head?: false}},
          {base, %{decision: :failed, review_decision: "REVIEW_REQUIRED", reviewed_head?: false}},
          {base, %{decision: :pending, review_decision: "REVIEW_REQUIRED", reviewed_head?: false}},
          {base, %{decision: :passed, review_decision: "APPROVED", reviewed_head?: true}},
          {Map.put(base, :head_sha, String.duplicate("c", 40)), %{decision: :passed, review_decision: "REVIEW_REQUIRED", reviewed_head?: false}},
          {base, %{decision: :passed, review_decision: "REVIEW_REQUIRED"}},
          {base, %{decision: :passed, review_decision: "REVIEW_REQUIRED", reviewed_head?: true}}
        ] do
      assert ReadyForReviewTransitions.re_raise_unreviewed(state, observation, result, opts) == state
    end

    refute_received :unexpected
  end

  test "a CI poll re-raises a reworked head handed back to human review, and skips a ticket not in review" do
    head = String.duplicate("d", 40)
    test_pid = self()

    emitter = fn topic, opts ->
      if String.ends_with?(topic, ".unreviewed_ready_pr"), do: send(test_pid, {:attention, topic, opts})
      :ok
    end

    # A --request-changes review keeps reviewDecision at CHANGES_REQUESTED after the fix is pushed.
    result = %{decision: :passed, pr_number: 79, head_sha: head, draft?: false, ready_at_ms: 1_000, review_decision: "CHANGES_REQUESTED", reviewed_head?: false}
    opts = [age_limit_ms: 1, repo_fun: fn -> "owner/repo" end, alert_emitter: emitter]

    ticket = issue(unique_identifier("unreviewed-handback"), "human-review")
    # The ready-history read already classified this PR; the CI poll turns that into a tracked head.
    _ = poll_ci(%State{pr_ready_ledger: %{{ticket.identifier, 79} => :never_draft}}, ticket, result, opts)
    topic = "ticket.#{ticket.identifier}.agent.attention.unreviewed_ready_pr"
    assert_received {:attention, ^topic, attention}
    assert attention[:message] =~ head

    waiting = issue(unique_identifier("unreviewed-ci-wait"), "ci-wait")
    _ = poll_ci(%State{pr_ready_ledger: %{{waiting.identifier, 79} => :never_draft}}, waiting, result, opts)
    refute_received {:attention, _, _}
  end
end
