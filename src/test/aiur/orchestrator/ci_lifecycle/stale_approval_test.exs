defmodule Aiur.Orchestrator.CiLifecycle.StaleApprovalTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.Events.Exchange
  alias Aiur.Orchestrator.CiLifecycle

  setup :ci_lifecycle_setup

  test "a new ci-wait head after approval raises attention without a green head record" do
    identifier = unique_identifier("ci-stale-approved-head")
    topic = "ticket.#{identifier}.agent.attention.stale_approved_pr_head"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}

    state =
      issue
      |> running_state(recorder, :paused, paused_reason: :ci_wait)
      |> CiLifecycle.pause_issue_for_ci_wait(issue)

    next =
      poll_ci(state, issue, %{
        decision: :pending,
        head_sha: "pushed-head",
        pr_number: 944,
        review_decision: "APPROVED",
        approved_review_head_sha: "approved-head"
      })

    assert_receive {:event, %{"needs_attention" => true, topic: ^topic}}, 500
    refute_received {:recorded, _, {:tracker_update, ^identifier, "rework", _}}
    assert next.running[identifier].issue.state == "ci-wait"
  end

  test "a new unapproved head does not raise stale approval attention" do
    identifier = unique_identifier("ci-unapproved-new-head")
    topic = "ticket.#{identifier}.agent.attention.stale_approved_pr_head"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)
    recorder = start_recorder()
    issue = issue(identifier, "ci-wait")

    state = running_state(issue, recorder, :paused, paused_reason: :ci_wait)

    next =
      poll_ci(state, issue, %{
        decision: :pending,
        head_sha: "pushed-head",
        pr_number: 945,
        review_decision: "REVIEW_REQUIRED",
        approved_review_head_sha: nil
      })

    refute_received {:event, %{"needs_attention" => true, topic: ^topic}}
    assert next.running[identifier].issue.state == "ci-wait"
  end
end
