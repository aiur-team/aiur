defmodule Aiur.Orchestrator.CiLifecycle.WaitingReworkTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  defp review(head), do: %{"state" => "CHANGES_REQUESTED", "commit_id" => head, "submitted_at" => "2026-10-13T00:00:00Z", "id" => 1, "user" => %{"login" => "reviewer"}, authoritative: true}

  for label <- ["ci-wait", "human-review"] do
    test "first CI poll routes a #{label} ticket with current changes requested findings to rework" do
      identifier = unique_identifier("restart-review-rework")
      RecordingGitHubClient.record_to(self())

      next =
        poll_ci(
          %State{},
          issue(identifier, unquote(label)),
          %{decision: :pending, head_sha: "review-head", pr_number: 4388, review_decision: "CHANGES_REQUESTED"},
          reviews_fetcher: fn 4388, _opts -> {:ok, [review("review-head")]} end
        )

      assert_received {:tracker_update, ^identifier, "rework", [expected_state: unquote(label)]}
      assert next.ci_lifecycle.poll_cache[identifier].review_decision == "CHANGES_REQUESTED"
    end

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
  end

  test "sticky changes requested does not route a head that has a newer commit" do
    # Future-regression guard: the sticky decision must not route an older-head review.
    identifier = unique_identifier("restart-stale-review")
    RecordingGitHubClient.record_to(self())

    _next =
      poll_ci(
        %State{},
        issue(identifier, "ci-wait"),
        %{decision: :pending, head_sha: "new-head", pr_number: 4390, review_decision: "CHANGES_REQUESTED"},
        reviews_fetcher: fn 4390, _opts -> {:ok, [review("reviewed-head")]} end
      )

    refute_received {:tracker_update, ^identifier, "rework", _opts}
  end
end
