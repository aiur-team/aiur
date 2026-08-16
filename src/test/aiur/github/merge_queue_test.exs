defmodule Aiur.GitHub.MergeQueueTest do
  use ExUnit.Case, async: true

  alias Aiur.GitHub.MergeQueue

  describe "normalize_graphql_pull_request/1" do
    test "normalizes the fields used to decide whether recovery is needed" do
      assert MergeQueue.normalize_graphql_pull_request(%{
               "id" => "PR_1",
               "isDraft" => false,
               "reviewDecision" => "APPROVED",
               "mergeable" => "MERGEABLE",
               "mergeStateStatus" => "BLOCKED",
               "autoMergeRequest" => nil,
               "mergeQueueEntry" => nil
             }) == %{
               draft?: false,
               review_decision: "APPROVED",
               mergeable: "MERGEABLE",
               merge_state_status: "BLOCKED",
               auto_merge_request: nil,
               merge_queue_entry: nil
             }
    end

    test "returns an error for an incomplete GraphQL observation" do
      assert MergeQueue.normalize_graphql_pull_request(%{"id" => "PR_1"}) ==
               {:error, :incomplete_observation}

      assert MergeQueue.normalize_graphql_pull_request(:not_a_map) ==
               {:error, :invalid_observation}
    end
  end

  describe "recovery_state/1" do
    test "classifies an approved ready mergeable BLOCKED pull request as unarmed" do
      assert MergeQueue.recovery_state(%{
               draft?: false,
               review_decision: "APPROVED",
               mergeable: "MERGEABLE",
               merge_state_status: "BLOCKED",
               auto_merge_request: nil,
               merge_queue_entry: nil
             }) == :unarmed
    end

    test "distinguishes auto-merge arming and direct queue entry" do
      base = %{
        draft?: false,
        review_decision: "APPROVED",
        mergeable: "MERGEABLE",
        merge_state_status: "BLOCKED",
        auto_merge_request: nil,
        merge_queue_entry: nil
      }

      assert base
             |> Map.put(:auto_merge_request, %{enabled_at: "2026-08-11T20:00:00Z"})
             |> MergeQueue.recovery_state() == :armed

      assert base
             |> Map.put(:merge_queue_entry, %{id: "MQE_1"})
             |> MergeQueue.recovery_state() == :queued
    end

    test "classifies known non-candidates without treating incomplete observations as clear" do
      base = %{
        draft?: false,
        review_decision: "APPROVED",
        mergeable: "MERGEABLE",
        merge_state_status: "BLOCKED",
        auto_merge_request: nil,
        merge_queue_entry: nil
      }

      assert base |> Map.put(:draft?, true) |> MergeQueue.recovery_state() == :ineligible
      assert base |> Map.put(:review_decision, "REVIEW_REQUIRED") |> MergeQueue.recovery_state() == :ineligible
      assert base |> Map.put(:mergeable, "CONFLICTING") |> MergeQueue.recovery_state() == :ineligible
      assert MergeQueue.recovery_state(Map.delete(base, :auto_merge_request)) == :unknown
      assert MergeQueue.recovery_state(%{}) == :unknown
    end

    test "fails closed on ambiguous or malformed observation state" do
      base = %{
        draft?: false,
        review_decision: "APPROVED",
        mergeable: "MERGEABLE",
        merge_state_status: "BLOCKED",
        auto_merge_request: nil,
        merge_queue_entry: nil
      }

      # A non-nil, non-map auto-merge/queue field means the poll returned
      # something GitHub never produces; treat it as unknown, not as a signal
      # that recovery is armed or queued.
      assert base |> Map.put(:auto_merge_request, "not-a-map") |> MergeQueue.recovery_state() == :unknown
      assert base |> Map.put(:merge_queue_entry, 0) |> MergeQueue.recovery_state() == :unknown

      # GitHub reports `mergeable: UNKNOWN` while it is still computing
      # mergeability; do not arm or clear on an unknown value.
      assert base |> Map.put(:mergeable, "UNKNOWN") |> MergeQueue.recovery_state() == :unknown

      # A missing draft flag is not a ready PR; do not classify it as unarmed.
      assert base |> Map.put(:draft?, nil) |> MergeQueue.recovery_state() == :unknown
    end
  end
end
