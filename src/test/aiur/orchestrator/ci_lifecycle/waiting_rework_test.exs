defmodule Aiur.Orchestrator.CiLifecycle.WaitingReworkTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  for label <- ["ci-wait", "human-review"] do
    test "a #{label} ticket moves to rework after two conflicting polls" do
      identifier = unique_identifier("restart-conflict-rework")
      RecordingGitHubClient.record_to(self())

      ticket = issue(identifier, unquote(label))
      first = poll_ci(%State{}, ticket, %{decision: :pending, head_sha: "conflicting-head", pr_number: 4389, mergeable: "CONFLICTING"})
      refute_received {:tracker_update, ^identifier, "rework", _opts}

      next = poll_ci(first, ticket, %{decision: :pending, head_sha: "conflicting-head", pr_number: 4389, mergeable: "CONFLICTING"})

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
      assert_received {:tracker_comment, ^identifier, body}
      assert body =~ "mergeable: CONFLICTING"
      assert body =~ "merge main"
      assert State.rework_attempt_count(next, identifier, "conflicting-head") == 1
    end

    test "a delivered conflicting read does not count toward the streak for #{label}" do
      identifier = unique_identifier("delivered-conflict-inert")
      RecordingGitHubClient.record_to(self())
      ticket = issue(identifier, unquote(label))
      delivered = poll_ci(%State{}, ticket, %{delivered: true, decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "CONFLICTING"})
      first_live = poll_ci(delivered, ticket, %{decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "CONFLICTING"})

      refute_received {:tracker_update, ^identifier, "rework", _opts}
      assert first_live.ci_lifecycle.poll_cache[identifier].conflicting_polls == 1

      _next = poll_ci(first_live, ticket, %{decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "CONFLICTING"})

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
    end

    test "an UNKNOWN poll breaks the consecutive conflict streak for #{label}" do
      identifier = unique_identifier("unknown-conflict-reset")
      RecordingGitHubClient.record_to(self())
      ticket = issue(identifier, unquote(label))
      first = poll_ci(%State{}, ticket, %{decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "CONFLICTING"})
      unknown = poll_ci(first, ticket, %{decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "UNKNOWN"})

      _next = poll_ci(unknown, ticket, %{decision: :pending, head_sha: "head", pr_number: 4389, mergeable: "CONFLICTING"})

      refute_received {:tracker_update, ^identifier, "rework", _opts}
    end

    for mergeable <- ["UNKNOWN", "MERGEABLE", nil] do
      test "a #{label} ticket whose PR mergeable is #{inspect(mergeable)} is not routed to rework" do
        identifier = unique_identifier("not-conflicting")
        RecordingGitHubClient.record_to(self())

        _next = poll_ci(%State{}, issue(identifier, unquote(label)), %{decision: :pending, head_sha: "head", pr_number: 4391, mergeable: unquote(mergeable)})

        refute_received {:tracker_update, ^identifier, "rework", _opts}
      end
    end

    test "a #{label} conflicting head already routed to the rework limit is not routed again" do
      identifier = unique_identifier("conflict-loop")
      RecordingGitHubClient.record_to(self())
      limit = State.rework_attempt_limit()
      state = %State{rework_attempts: %{{identifier, "stuck-head"} => limit}}
      ticket = issue(identifier, unquote(label))
      first = poll_ci(state, ticket, %{decision: :pending, head_sha: "stuck-head", pr_number: 4392, mergeable: "CONFLICTING"})

      _next = poll_ci(first, ticket, %{decision: :pending, head_sha: "stuck-head", pr_number: 4392, mergeable: "CONFLICTING"})

      refute_received {:tracker_update, ^identifier, "rework", _opts}
    end

    test "a #{label} conflicting PR approved at its head routes after two polls" do
      identifier = unique_identifier("approved-conflict")
      RecordingGitHubClient.record_to(self())
      result = %{decision: :pending, head_sha: "approved-head", pr_number: 4393, mergeable: "CONFLICTING", review_decision: "APPROVED", approved_review_head_sha: "approved-head"}

      ticket = issue(identifier, unquote(label))
      first = poll_ci(%State{}, ticket, result)
      refute_received {:tracker_update, ^identifier, "rework", _opts}

      _next = poll_ci(first, ticket, result)

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
    end

    test "a #{label} conflicting PR approved only at an older head is routed to rework" do
      identifier = unique_identifier("stale-approved-conflict")
      RecordingGitHubClient.record_to(self())
      result = %{decision: :pending, head_sha: "new-head", pr_number: 4394, mergeable: "CONFLICTING", review_decision: "APPROVED", approved_review_head_sha: "old-head"}

      ticket = issue(identifier, unquote(label))
      first = poll_ci(%State{}, ticket, result)
      refute_received {:tracker_update, ^identifier, "rework", _opts}

      _next = poll_ci(first, ticket, result)

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
    end
  end
end
