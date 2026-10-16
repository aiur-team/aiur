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
      poll_ci(
        state,
        issue,
        %{
          decision: :pending,
          head_sha: "pushed-head",
          pr_number: 944,
          review_decision: "APPROVED",
          approved_review_head_sha: "approved-head"
        },
        approval_carry_classifier: fn _approved, _head, _pr, _opts -> {:changed, %{reason: {:unavailable, :test}, hunks: []}} end
      )

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

  defp approved_push(identifier, pr_number) do
    recorder = start_recorder()
    issue = %{issue(identifier, "ci-wait") | state_labels: ["ci-wait"]}
    state = issue |> running_state(recorder, :paused, paused_reason: :ci_wait) |> CiLifecycle.pause_issue_for_ci_wait(issue)
    result = %{decision: :pending, head_sha: "merged-head", pr_number: pr_number, review_decision: "APPROVED", approved_review_head_sha: "approved-head"}
    {issue, state, result}
  end

  defp classifier_opts(verdict) do
    test_pid = self()

    [
      approval_carry_classifier: fn approved, head, pr, _opts ->
        send(test_pid, {:classified, approved, head, pr})
        verdict
      end,
      approval_carry_commenter: fn pr, body -> send(test_pid, {:commented, pr, body}) end
    ]
  end

  test "a merge-only push after approval carries the approval without raising attention" do
    identifier = unique_identifier("ci-carried-approval")
    stale_topic = "ticket.#{identifier}.agent.attention.stale_approved_pr_head"
    carried_topic = "ticket.#{identifier}.pr.approval_carried"
    for topic <- [stale_topic, carried_topic], do: :ok = Exchange.subscribe(topic)
    on_exit(fn -> for topic <- [stale_topic, carried_topic], do: Exchange.unsubscribe(topic) end)
    {issue, state, result} = approved_push(identifier, 946)
    opts = classifier_opts(:carried)

    next = poll_ci(state, issue, result, opts)

    assert_received {:classified, "approved-head", "merged-head", 946}
    assert_received {:commented, "946", body}
    assert body =~ "carried the approval from `approved-head` to `merged-head`"
    assert_receive {:event, %{"needs_attention" => false, topic: ^carried_topic}}, 500
    refute_received {:event, %{topic: ^stale_topic}}

    # The same head pair is classified once; later polls spend no GitHub reads on it.
    _ = poll_ci(next, issue, result, opts)
    refute_received {:classified, _, _, _}
    refute_received {:event, %{topic: ^stale_topic}}
  end

  test "a push that edits a PR-owned line raises attention with the differing hunk" do
    identifier = unique_identifier("ci-changed-approval")
    topic = "ticket.#{identifier}.agent.attention.stale_approved_pr_head"
    :ok = Exchange.subscribe(topic)
    on_exit(fn -> Exchange.unsubscribe(topic) end)
    {issue, state, result} = approved_push(identifier, 947)
    hunk = %{file: "src/lib/a.ex", side: :current, header: "@@ -7,7 +7,7 @@", lines: ["-old", "+feature_v2"]}

    poll_ci(state, issue, result, classifier_opts({:changed, %{reason: :contribution_changed, hunks: [hunk]}}))

    assert_receive {:event, %{"needs_attention" => true, "reason" => reason, topic: ^topic}}, 500
    assert reason =~ "src/lib/a.ex (new head only) @@ -7,7 +7,7 @@\n-old\n+feature_v2"
    refute_received {:commented, _, _}
  end
end
