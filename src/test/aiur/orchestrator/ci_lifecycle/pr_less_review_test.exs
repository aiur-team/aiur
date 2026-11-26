defmodule Aiur.Orchestrator.CiLifecycle.PrLessReviewTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  @no_pr %{decision: :pending, pending_reason: :open_pr_not_yet_visible}

  test "a human-review ticket whose only PR merged is not moved to ci-wait and raises exactly one attention" do
    identifier = unique_identifier("pr-less-review")
    recorder = start_recorder()
    issue = issue(identifier, "human-review")
    state = running_state(issue, recorder, :working, [])
    ref = make_ref()
    emitter = capture_alert_emitter(self(), ref)

    next = Enum.reduce(1..3, state, fn _poll, acc -> poll_ci(acc, issue, @no_pr, alert_emitter: emitter) end)
    sync_recorder(recorder)

    refute_received {:recorded, _seq, {:tracker_update, ^identifier, _target, _opts}}
    assert next.running[identifier].issue.state == "human-review"

    topic = "ticket.#{identifier}.pr.human_review_without_pr"
    assert_received {:parked_alert, ^ref, ^topic, opts}
    assert Keyword.get(opts, :needs_attention) == true
    refute_received {:parked_alert, ^ref, _topic, _opts}
  end

  test "a single missed PR lookup raises no attention" do
    identifier = unique_identifier("pr-less-review-transient")
    issue = issue(identifier, "human-review")
    ref = make_ref()

    poll_ci(running_state(issue, self(), :working, []), issue, @no_pr, alert_emitter: capture_alert_emitter(self(), ref))

    refute_received {:parked_alert, ^ref, _topic, _opts}
  end

  test "resolves the attention once the ticket leaves the poll set" do
    identifier = unique_identifier("pr-less-review-departed")
    issue = issue(identifier, "human-review")
    ref = make_ref()
    emitter = capture_alert_emitter(self(), ref)

    state = Enum.reduce(1..2, running_state(issue, self(), :working, []), fn _poll, acc -> poll_ci(acc, issue, @no_pr, alert_emitter: emitter) end)
    assert_received {:parked_alert, ^ref, _raised, _opts}

    next =
      CiLifecycle.poll_github_ci(state,
        ci_issue_fetcher: fn ["ci-wait", "human-review"] -> {:ok, []} end,
        alert_emitter: emitter,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end
      )

    resolved = "ticket.#{identifier}.pr.human_review_without_pr.resolved"
    assert_received {:parked_alert, ^ref, ^resolved, resolve_opts}
    assert Keyword.get(resolve_opts, :needs_attention) == false
    assert next.ci_lifecycle.pr_less_review == %{}
  end
end
