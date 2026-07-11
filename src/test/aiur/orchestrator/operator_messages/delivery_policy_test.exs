defmodule Aiur.Orchestrator.OperatorMessages.DeliveryPolicyTest do
  use ExUnit.Case, async: true

  alias Aiur.Opencode.ActiveTurns
  alias Aiur.Orchestrator.OperatorMessages.DeliveryPolicy

  test "normalizes every delivery request against backend capabilities" do
    interrupt_capable = %{can_interrupt: true, immediate_delivery: false}
    immediate_capable = %{can_interrupt: false, immediate_delivery: true}
    checkpoint_only = %{can_interrupt: false, immediate_delivery: false}

    assert DeliveryPolicy.normalize_delivery_request(:auto, nil, immediate_capable) ==
             {:ok, delivery_policy: :immediate}

    assert DeliveryPolicy.normalize_delivery_request(:auto, nil, checkpoint_only) ==
             {:ok, delivery_policy: :checkpoint}

    assert DeliveryPolicy.normalize_delivery_request(:immediate, nil, immediate_capable) ==
             {:ok, delivery_policy: :immediate}

    assert DeliveryPolicy.normalize_delivery_request(:immediate, nil, checkpoint_only) ==
             {:error, :immediate_not_supported}

    assert DeliveryPolicy.normalize_delivery_request(:checkpoint, nil, immediate_capable) ==
             {:ok, delivery_policy: :checkpoint}

    assert DeliveryPolicy.normalize_delivery_request(:interrupt, :queue_next, interrupt_capable) ==
             {:ok, delivery_policy: :interrupt, fallback: :queue_next}

    assert DeliveryPolicy.normalize_delivery_request(:interrupt, :queue_next, checkpoint_only) ==
             {:ok, delivery_policy: :checkpoint, fallback: :queue_next}

    assert DeliveryPolicy.normalize_delivery_request(:interrupt, nil, checkpoint_only) ==
             {:error, :interrupt_not_supported}

    assert DeliveryPolicy.normalize_delivery_request(:unknown, nil, checkpoint_only) ==
             {:error, :invalid_message}
  end

  test "classifies comment event topics for atom and string payloads" do
    assert DeliveryPolicy.comment_event_topic?(%{topic: "ticket.42.pr.review_comment"})
    assert DeliveryPolicy.comment_event_topic?(%{"topic" => "ticket.42.issue.commented"})

    refute DeliveryPolicy.comment_event_topic?(%{topic: "ticket.42.branch.push"})
    refute DeliveryPolicy.comment_event_topic?(%{topic: nil})
    refute DeliveryPolicy.comment_event_topic?(:not_an_event)
  end

  test "digest delivery wakes sleepers and idle agents but not paused agents" do
    event = %{topic: "ticket.42.branch.push"}

    assert DeliveryPolicy.event_digest_delivery_opts(nil, event) == [source: :system]

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry("42-sleep", :sleeping), event) ==
             [source: :system, priority: :now, interrupt_requested: true]

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry("42-idle", :working), event) ==
             [source: :system, priority: :now, interrupt_requested: true]

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry("42-paused", :paused), event) ==
             [source: :system]
  end

  test "trusted actionable comments wake an active turn" do
    identifier = "delivery-policy-#{System.unique_integer([:positive])}"
    turn_id = "turn-#{System.unique_integer([:positive])}"
    :ok = ActiveTurns.put(identifier, turn_id)
    on_exit(fn -> ActiveTurns.mark_closed(identifier, turn_id, :test_cleanup) end)

    running_entry = running_entry(identifier, :working)
    branch_event = %{topic: "ticket.#{identifier}.branch.push"}

    trusted_comment = %{
      topic: "ticket.#{identifier}.pr.review_comment",
      author_trusted?: true,
      comment: %{body: "please fix"}
    }

    benign_comment = put_in(trusted_comment, [:comment, :body], "[codex] review passed")

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry, branch_event) == [
             source: :system
           ]

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry, trusted_comment) ==
             [source: :system, priority: :now, interrupt_requested: true]

    assert DeliveryPolicy.event_digest_delivery_opts(running_entry, benign_comment) == [
             source: :system
           ]
  end

  defp running_entry(identifier, status) do
    %{identifier: identifier, control: %{status: status}}
  end
end
