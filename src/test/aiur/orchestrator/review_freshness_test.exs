defmodule Aiur.Orchestrator.ReviewFreshnessTest do
  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.ReviewFreshness

  # The #1756 fixture: a CHANGES_REQUESTED review submitted before the current
  # head commit was authored. Every finding was fixed by the push that produced
  # that head, but GitHub still reports `reviewDecision: CHANGES_REQUESTED`.
  @head_committed_at "2026-08-10T04:29:00Z"
  @review_submitted_at "2026-08-08T21:15:00Z"

  defp event(comment_at, pull_request) do
    %{
      issue_number: "1583",
      author_trusted?: true,
      comment: %{"state" => "CHANGES_REQUESTED", "body" => "please fix", "submitted_at" => comment_at},
      pull_request: pull_request
    }
  end

  describe "rework_skip_reason/1 with a stale review" do
    test "skips a review submitted before the current head commit" do
      event = event(@review_submitted_at, %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at})

      assert ReviewFreshness.rework_skip_reason(event) == :stale_review
    end

    test "does not skip a review submitted after the current head commit" do
      event = event("2026-08-10T05:00:00Z", %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at})

      assert ReviewFreshness.rework_skip_reason(event) == nil
    end

    test "does not skip a review submitted at the head commit timestamp" do
      # Same-second is ambiguous; the safe reading is that the review is live.
      event = event(@head_committed_at, %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => @head_committed_at})

      assert ReviewFreshness.rework_skip_reason(event) == nil
    end

    test "falls back to created_at when the comment has no submitted_at" do
      event = %{
        comment: %{"body" => "still broken", "created_at" => @review_submitted_at},
        pull_request: %{"head_committed_at" => @head_committed_at}
      }

      assert ReviewFreshness.rework_skip_reason(event) == :stale_review
    end
  end

  describe "rework_skip_reason/1 with an approved pull request" do
    test "skips an APPROVED pull request even when the comment is newer than the head" do
      # The #1747 variant: reviewDecision was APPROVED and the ticket still
      # burned two no-op rework turns.
      event = event("2026-08-10T06:00:00Z", %{"review_decision" => "APPROVED", "head_committed_at" => @head_committed_at})

      assert ReviewFreshness.rework_skip_reason(event) == :approved_pull_request
    end

    test "skips an APPROVED pull request with no head timestamp at all" do
      event = event("2026-08-10T06:00:00Z", %{"review_decision" => "APPROVED"})

      assert ReviewFreshness.rework_skip_reason(event) == :approved_pull_request
    end

    test "does not skip a REVIEW_REQUIRED pull request with a current review" do
      event = event("2026-08-10T06:00:00Z", %{"review_decision" => "REVIEW_REQUIRED", "head_committed_at" => @head_committed_at})

      assert ReviewFreshness.rework_skip_reason(event) == nil
    end
  end

  describe "rework_skip_reason/1 fails open" do
    test "does not skip when the event carries no pull request context" do
      assert ReviewFreshness.rework_skip_reason(%{comment: %{"body" => "fix this"}}) == nil
    end

    test "does not skip when the head timestamp is unparseable" do
      event = event(@review_submitted_at, %{"head_committed_at" => "not-a-timestamp"})

      assert ReviewFreshness.rework_skip_reason(event) == nil
    end

    test "does not skip when the comment carries no timestamp" do
      event = %{comment: %{"body" => "fix this"}, pull_request: %{"head_committed_at" => @head_committed_at}}

      assert ReviewFreshness.rework_skip_reason(event) == nil
    end

    test "does not skip a non-map event" do
      assert ReviewFreshness.rework_skip_reason(nil) == nil
    end
  end

  describe "rework_skip_reason/1 key shapes" do
    test "reads string keys from a JSON round trip through the event store" do
      event = %{
        "comment" => %{"submitted_at" => @review_submitted_at},
        "pull_request" => %{"head_committed_at" => @head_committed_at}
      }

      assert ReviewFreshness.rework_skip_reason(event) == :stale_review
    end

    test "reads a lowercase review decision" do
      event = event("2026-08-10T06:00:00Z", %{"review_decision" => "approved"})

      assert ReviewFreshness.rework_skip_reason(event) == :approved_pull_request
    end
  end
end
