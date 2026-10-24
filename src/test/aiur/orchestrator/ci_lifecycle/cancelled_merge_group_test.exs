defmodule Aiur.Orchestrator.CiLifecycle.CancelledMergeGroupTest do
  use Aiur.TestSupport

  import Aiur.CiLifecycleTestSupport

  alias Aiur.CiLifecycleTestSupport.RecordingGitHubClient
  alias Aiur.LandingWatch.MergeFailureClassifier
  alias Aiur.Orchestrator.CiLifecycle
  alias Aiur.Orchestrator.CiLifecycle.CancelledMergeGroup
  alias Aiur.Orchestrator.State

  setup :ci_lifecycle_setup

  test "an all-cancelled merge-group run cannot rework or dequeue an approved queued ticket" do
    identifier = unique_identifier("cancelled-merge-group")
    RecordingGitHubClient.record_to(self())
    ticket = issue(identifier, "ci-wait")

    cancelled_jobs = [
      %{"name" => "test", "conclusion" => "cancelled"},
      %{"name" => "lint", "conclusion" => "cancelled"},
      %{"name" => "ci gate", "conclusion" => "failure"}
    ]

    base = %State{}

    state = %{
      base
      | ci_lifecycle: %{
          base.ci_lifecycle
          | poll_cache: %{
              identifier => %{
                decision: :pending,
                head_sha: "same-head",
                review_decision: "APPROVED",
                merge_queue_entry: %{"id" => "queue-entry", "state" => "AWAITING_CHECKS"}
              }
            }
        }
    }

    next =
      CiLifecycle.poll_github_ci(state,
        ci_recovery_enabled: false,
        ci_issue_fetcher: fn _ -> {:ok, [ticket]} end,
        ci_poller: fn _targets, _opts ->
          {:ok,
           %{
             results: [
               %{
                 target: identifier,
                 decision: :passed,
                 head_sha: "same-head",
                 pr_number: 71,
                 review_decision: "APPROVED",
                 merge_queue_entry: nil
               }
             ],
             errors: []
           }}
        end,
        cancelled_merge_group_fun: fn 71, _opts ->
          MergeFailureClassifier.cancelled_group?(%{"event" => "merge_group", "conclusion" => "failure"}, cancelled_jobs)
        end,
        withdraw_landing: fn _number -> flunk("cancelled CI must not dequeue the approved PR") end,
        parked_ready_alert_loader: fn -> MapSet.new() end,
        draft_stall_alert_loader: fn -> MapSet.new() end
      )

    refute_received {:tracker_update, ^identifier, "rework", _}
    assert next.running == %{}
  end

  test "an all-cancelled merge-group failure overrides the synthetic queue failure" do
    result = %{
      decision: :failed,
      pending_reason: :merge_queue_failed,
      head_sha: "same-head",
      review_decision: "APPROVED",
      cancelled_merge_group?: true,
      failures: [%{name: "merge queue", kind: "merge_queue", result: "UNMERGEABLE"}]
    }

    previous = %{
      head_sha: "same-head",
      merge_queue_entry: %{"id" => "queue-entry", "state" => "UNMERGEABLE"}
    }

    assert %{
             decision: :pending,
             pending_reason: :ci_cancelled,
             failures: []
           } = CancelledMergeGroup.classify_departure(result, previous)
  end
end
