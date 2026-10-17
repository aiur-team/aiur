defmodule Aiur.Orchestrator.CiLifecycle.WaitingReworkTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  for label <- ["ci-wait", "human-review"] do
    test "first CI poll routes a #{label} ticket with a conflicting PR to rework" do
      identifier = unique_identifier("restart-conflict-rework")
      RecordingGitHubClient.record_to(self())

      next = poll_ci(%State{}, issue(identifier, unquote(label)), %{decision: :pending, head_sha: "conflicting-head", pr_number: 4389, mergeable: "CONFLICTING"})

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
      assert State.rework_attempt_count(next, identifier, "conflicting-head") == 1
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

      _next = poll_ci(state, issue(identifier, unquote(label)), %{decision: :pending, head_sha: "stuck-head", pr_number: 4392, mergeable: "CONFLICTING"})

      refute_received {:tracker_update, ^identifier, "rework", _opts}
    end

    test "a #{label} conflicting PR approved at its head is left to LandingWatch" do
      identifier = unique_identifier("approved-conflict")
      RecordingGitHubClient.record_to(self())
      result = %{decision: :pending, head_sha: "approved-head", pr_number: 4393, mergeable: "CONFLICTING", review_decision: "APPROVED", approved_review_head_sha: "approved-head"}

      _next = poll_ci(%State{}, issue(identifier, unquote(label)), result)

      refute_received {:tracker_update, ^identifier, "rework", _opts}
    end

    test "a #{label} conflicting PR approved only at an older head is routed to rework" do
      identifier = unique_identifier("stale-approved-conflict")
      RecordingGitHubClient.record_to(self())
      result = %{decision: :pending, head_sha: "new-head", pr_number: 4394, mergeable: "CONFLICTING", review_decision: "APPROVED", approved_review_head_sha: "old-head"}

      _next = poll_ci(%State{}, issue(identifier, unquote(label)), result)

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
    end
  end
end
