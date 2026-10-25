defmodule Aiur.Events.Outbound.EventTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.Event, as: MembershipEvent
  alias Aiur.CurrentRunMembership.OutboundEvents, as: MembershipOutboundEvents
  alias Aiur.Events.Outbound.Event
  alias Aiur.Orchestrator.Cancellation.OutboundEvents, as: CancellationOutboundEvents
  alias Aiur.TicketObservation
  alias Aiur.TrackerIdentity
  alias Aiur.UsageEnvelope.ExactMoney
  alias Aiur.UsageLedger.OutboundEvents, as: UsageOutboundEvents

  @fixtures Path.expand("../../../../../packages/aiur-contracts/fixtures", __DIR__)
  @emitted_at ~U[2026-10-25 00:00:00Z]
  @observed_at ~U[2026-10-25 00:00:00Z]

  test "normalizes all five event families to the package fixtures" do
    identity = identity()
    {:ok, membership} = MembershipEvent.new("run-5695-1", identity, :running, @observed_at, source: :tracker)

    lifecycle =
      MembershipOutboundEvents.payload(membership)
      |> Map.merge(%{
        id: 101,
        topic: "ticket.5695.lifecycle.changed",
        ticket_observation: observation(identity, 101, %{kind: :legacy, name: "outbound_source"})
      })

    progress = %{
      id: 102,
      topic: "ticket.5695.agent.progress.checkin",
      ticket_observation: %TicketObservation{
        status: :joinable,
        reason: nil,
        tracker_identity: identity,
        source: %{kind: :agent_event, name: "progress.checkin"},
        event_id: 102,
        provenance: %{run_id: "run-5695-1"},
        occurred_at: @observed_at,
        observed_at: DateTime.add(@observed_at, 1, :second),
        attributes: %{percent: 40}
      }
    }

    usage =
      UsageOutboundEvents.payload(acknowledgement())
      |> Map.merge(%{
        id: 103,
        topic: "ticket.5695.usage.changed",
        ticket_observation: observation(identity, 103, %{kind: :legacy, name: "outbound_source"})
      })

    spend_identity = identity("5693")

    spend_cap =
      fixture("ticket-spend-cap-reached.v1.json")
      |> Map.merge(%{
        id: 104,
        topic: "ticket.5693.usage.spend_cap_reached",
        ticket_observation: observation(spend_identity, 104, %{kind: :legacy, name: "spend_cap"}, "5693")
      })

    cancel_identity = identity("5698")

    cancel_result =
      fixture("ticket-cancel.v1.json")
      |> CancellationOutboundEvents.payload()
      |> Map.merge(%{
        id: 105,
        topic: "ticket.5698.cancel.result",
        ticket_observation: observation(cancel_identity, 105, %{kind: :legacy, name: "outbound_source"}, nil)
      })

    assert {:ok, lifecycle_event} = Event.normalize(lifecycle, @emitted_at)
    assert {:ok, progress_event} = Event.normalize(progress, DateTime.add(@emitted_at, 1, :second))
    assert {:ok, usage_event} = Event.normalize(usage, DateTime.add(@emitted_at, 2, :second))
    assert {:ok, spend_cap_event} = Event.normalize(spend_cap, ~U[2026-10-24 20:01:00Z])
    assert {:ok, cancel_result_event} = Event.normalize(cancel_result, ~U[2026-10-23 12:00:00Z])

    assert lifecycle_event == fixture("ticket-lifecycle-event.v1.json")
    assert progress_event == fixture("ticket-progress-event.v1.json")
    assert usage_event == fixture("ticket-usage-event.v1.json")
    assert spend_cap_event == fixture("ticket-spend-cap-reached-event.v1.json")
    assert cancel_result_event == fixture("ticket-cancel-result-event.v1.json")
  end

  test "drops unattributed, malformed, and non-allowlisted internal events" do
    identity = identity()

    unattributed = %{
      id: 1,
      topic: "ticket.5695.agent.progress",
      ticket_observation: %TicketObservation{status: :unattributed, source: %{kind: :agent_event, name: "progress"}, attributes: %{percent: 50}}
    }

    malformed = %{
      id: 2,
      topic: "ticket.5695.agent.progress",
      ticket_observation: %TicketObservation{
        status: :joinable,
        tracker_identity: identity,
        source: %{kind: :agent_event, name: "progress"},
        observed_at: @observed_at,
        attributes: %{}
      }
    }

    malformed_usage = %{
      id: 4,
      topic: "ticket.5695.usage.changed",
      outbound_event: %{kind: :ticket_usage, data: %{"position" => 1, "generation" => 1, "delta" => %{"tokens" => %{}}}},
      ticket_observation: observation(identity, 4, %{kind: :legacy, name: "outbound_source"})
    }

    invalid_amount =
      UsageOutboundEvents.payload(acknowledgement())
      |> put_in([:outbound_event, :data, "delta", "cost", "amount"], "-1")
      |> Map.merge(%{
        id: 5,
        topic: "ticket.5695.usage.changed",
        ticket_observation: observation(identity, 5, %{kind: :legacy, name: "outbound_source"})
      })

    mismatched_event_id =
      MembershipEvent.new("run-5695-1", identity, :running, @observed_at, source: :tracker)
      |> then(fn {:ok, membership} -> MembershipOutboundEvents.payload(membership) end)
      |> Map.merge(%{
        id: 6,
        topic: "ticket.5695.lifecycle.changed",
        ticket_observation: observation(identity, 7, %{kind: :legacy, name: "outbound_source"})
      })

    assert :drop = Event.normalize(unattributed, @emitted_at)
    assert :drop = Event.normalize(malformed, @emitted_at)
    assert :drop = Event.normalize(malformed_usage, @emitted_at)
    assert :drop = Event.normalize(invalid_amount, @emitted_at)
    assert :drop = Event.normalize(mismatched_event_id, @emitted_at)
    assert :drop = Event.normalize(%{id: 3, topic: "ticket.5695.issue.commented"}, @emitted_at)
  end

  defp acknowledgement do
    {:ok, cost} =
      ExactMoney.decode(%{
        amount: "0.12",
        currency: "USD",
        unit: :major,
        measurement_kind: :delta,
        counter_scope: :thread,
        source: "provider-cost",
        source_version: "2026-10"
      })

    %{
      position: 17,
      generation: 17,
      delta: %{
        tokens: %{
          input: 10,
          cached_input: nil,
          cache_creation_input: nil,
          output: 3,
          reasoning_output: nil,
          provider_reported_total: 13
        },
        cost: cost,
        source_version: "2026-10",
        relationship_revision: "codex-app-server-2026-10",
        coverage_reasons: []
      }
    }
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  defp observation(identity, event_id, source, run_id \\ "run-5695-1") do
    %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity,
      source: source,
      event_id: event_id,
      provenance: %{run_id: run_id},
      occurred_at: @observed_at,
      observed_at: @observed_at,
      attributes: %{}
    }
  end

  defp identity(identifier \\ "5695") do
    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: "aiur-team",
      repository: "aiur",
      provider_id: "I_#{identifier}",
      database_id: String.to_integer(identifier),
      identifier: identifier,
      reason: nil
    }
  end
end
