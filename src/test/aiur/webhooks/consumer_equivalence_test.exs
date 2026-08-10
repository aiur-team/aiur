defmodule Aiur.Webhooks.ConsumerEquivalenceTest do
  @moduledoc """
  The consumer contract: nothing downstream may be able to tell which transport
  a repo is on.

  Every test here is written once and run twice — once against
  `EventSource.Polling` and once against `EventSource.Webhook` — by
  `Aiur.WebhookModeContract`. The bodies never mention a mode, which is the
  point: if a consumer ever needed to know the transport, one of these bodies
  could not be written without branching, and the branch would be the failure.
  """

  use ExUnit.Case, async: true
  use Aiur.WebhookModeContract

  mode_test "the consumer receives the normalized event unchanged", ctx do
    {:ok, event} = deliver(ctx, "ticket.1683.pr.opened", %{number: 1683, actor: "octocat"})

    assert_received {:published, published}
    assert published == event
    assert published.topic == "ticket.1683.pr.opened"
    assert published.payload == %{number: 1683, actor: "octocat"}
  end

  mode_test "topic and payload survive a burst in order", ctx do
    for n <- 1..3, do: deliver(ctx, "ticket.#{n}.branch.push", %{sha: "sha-#{n}"})

    for n <- 1..3 do
      assert_received {:published, %{topic: topic, payload: payload}}
      assert topic == "ticket.#{n}.branch.push"
      assert payload == %{sha: "sha-#{n}"}
    end
  end

  mode_test "the consumer is handed no transport marker to branch on", ctx do
    {:ok, event} = deliver(ctx, "ticket.1683.pr.merged", %{merged: true})

    assert Map.keys(event) |> Enum.sort() == [:payload, :topic]
    refute Map.has_key?(event.payload, :transport)
    refute Map.has_key?(event.payload, :delivery_mode)
    refute Map.has_key?(event.payload, :webhook)
  end

  mode_test "an empty payload is still delivered as an empty payload", ctx do
    {:ok, _event} = deliver(ctx, "ticket.1683.agent.progress", %{})

    assert_received {:published, published}
    assert published.topic == "ticket.1683.agent.progress"
    assert published.payload == %{}, "an empty payload must arrive empty, not enriched by the transport"
  end
end
