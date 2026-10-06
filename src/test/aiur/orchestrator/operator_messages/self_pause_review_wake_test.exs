defmodule Aiur.Orchestrator.OperatorMessages.SelfPauseReviewWakeTest do
  @moduledoc """
  A self-pause whose stated condition is "wait until human review produces
  feedback" must not survive the feedback arriving.

  Observed on aiur-team/khala #198 (PR #268): the agent finished its
  human-review handoff, was given eleven no-op continuation turns, and then
  emitted `agent.pause.request` — "Pause until human review produces feedback
  or merge handling". A formal `CHANGES_REQUESTED` review had landed seventeen
  seconds earlier. Aiur applied the pause anyway, and nothing cleared it: the
  trusted review digest was enqueued with `deliver_now?: false`, so
  `QueueDrain.claim_after_queue_update/3` returned `:ignored` and the paused
  runner looped back into `wait_for_operator_message/6`. The ticket showed
  `agent:rework` to every operator surface while no turn would ever start. Only
  `aiurdev resume 198` lifted it.

  This is the review-feedback twin of #2558 half two (a replayed decision
  answer that never woke its paused target). The pause blocked the very wake
  that would have cleared it.
  """

  use ExUnit.Case, async: true

  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy
  alias Aiur.Orchestrator.State

  describe "a trusted CHANGES_REQUESTED review reaching a self-paused agent" do
    test "requests the wake instead of being queued silently" do
      identifier = "self-pause-review-#{System.unique_integer([:positive])}"

      assert DeliveryPolicy.event_digest_delivery_opts(
               self_paused_entry(identifier),
               changes_requested_review(identifier)
             ) == [source: :system, priority: :now, interrupt_requested: true]
    end

    test "an operator pause is still woken only by its correlated resume" do
      identifier = "operator-pause-#{System.unique_integer([:positive])}"

      assert DeliveryPolicy.event_digest_delivery_opts(
               paused_entry(identifier, :operator_pause),
               changes_requested_review(identifier)
             ) == [source: :system]
    end

    test "a budget hold, a blocker pause and an outstanding decision stay parked" do
      for reason <- [:github_budget_hold, :blocker_dependency, :input_required, :ci_wait] do
        identifier = "parked-#{reason}-#{System.unique_integer([:positive])}"

        assert DeliveryPolicy.event_digest_delivery_opts(
                 paused_entry(identifier, reason),
                 changes_requested_review(identifier)
               ) == [source: :system],
               "#{inspect(reason)} must not be woken by a review comment"
      end
    end

    test "a self-paused agent is not woken by an untrusted or benign review event" do
      identifier = "benign-#{System.unique_integer([:positive])}"
      entry = self_paused_entry(identifier)

      # A push is not review feedback.
      assert DeliveryPolicy.event_digest_delivery_opts(entry, %{
               topic: "ticket.#{identifier}.branch.push"
             }) == [source: :system]

      # An untrusted author cannot lift the pause.
      assert DeliveryPolicy.event_digest_delivery_opts(
               entry,
               %{changes_requested_review(identifier) | author_trusted?: false}
             ) == [source: :system]

      # A passing review is not feedback to act on.
      assert DeliveryPolicy.event_digest_delivery_opts(
               entry,
               put_in(changes_requested_review(identifier), [:comment, :body], "[codex] review passed")
             ) == [source: :system]
    end
  end

  describe "notifying the paused runner" do
    test "tells it to deliver now, so the claim flips the entry to working" do
      identifier = "wake-now-#{System.unique_integer([:positive])}"
      entry = self_paused_entry(identifier) |> Map.put(:pid, self())

      :ok = DeliveryPolicy.notify_running_queue_update(%State{}, entry, review_item(identifier))

      assert_receive {:agent_queue_updated, ^identifier, "item-1", true}
    end

    test "an operator pause is still told not to deliver" do
      identifier = "wake-never-#{System.unique_integer([:positive])}"
      entry = paused_entry(identifier, :operator_pause) |> Map.put(:pid, self())

      :ok = DeliveryPolicy.notify_running_queue_update(%State{}, entry, review_item(identifier))

      assert_receive {:agent_queue_updated, ^identifier, "item-1", false}
    end
  end

  defp review_item(identifier) do
    %{
      id: "item-1",
      target_issue_identifier: identifier,
      delivery: [interrupt_requested: true]
    }
  end

  defp changes_requested_review(identifier) do
    %{
      topic: "ticket.#{identifier}.pr.review_comment",
      author_trusted?: true,
      comment: %{body: "Please prove the escape-heavy boundary."}
    }
  end

  defp self_paused_entry(identifier), do: paused_entry(identifier, :agent_pause_request)

  defp paused_entry(identifier, paused_reason) do
    %{
      identifier: identifier,
      control: %{status: :paused},
      paused_reason: paused_reason
    }
  end
end
