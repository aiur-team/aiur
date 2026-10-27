defmodule Aiur.Events.Outbound.EventTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.Event, as: MembershipEvent
  alias Aiur.CurrentRunMembership.OutboundEvents, as: MembershipOutboundEvents
  alias Aiur.Events.{Envelope, Outbound.Event}
  alias Aiur.Orchestrator.Cancellation.OutboundEvents, as: CancellationOutboundEvents
  alias Aiur.Orchestrator.SpendCap.OutboundEvents, as: SpendCapOutboundEvents
  alias Aiur.{TicketObservation, TrackerIdentity}
  alias Aiur.UsageLedger.OutboundEvents, as: UsageOutboundEvents

  @fixtures Path.expand("../../../../../packages/aiur-contracts/fixtures", __DIR__)
  @observed_at ~U[2026-10-25 00:00:00Z]

  test "the shared envelope builds all five webhook contract families" do
    identity = identity()
    {:ok, membership} = MembershipEvent.new("run-5695-1", identity, :running, @observed_at, source: :tracker)

    lifecycle =
      external(
        "ticket.5695.lifecycle.changed",
        MembershipOutboundEvents.payload(membership),
        101,
        identity,
        "run-5695-1"
      )

    progress =
      external(
        "ticket.5695.agent.progress.checkin",
        %{percent: 40, progress_source: "progress.checkin"},
        102,
        identity,
        "run-5695-1",
        source: %{kind: :agent_event, name: "progress.checkin"},
        observed_at: DateTime.add(@observed_at, 1, :second)
      )

    usage =
      external(
        "ticket.5695.usage.changed",
        UsageOutboundEvents.payload(%{position: 17, generation: 17}),
        103,
        identity,
        "run-5695-1"
      )

    spend_identity = identity("5693")

    spend_cap =
      external(
        "ticket.5693.usage.spend_cap_reached",
        SpendCapOutboundEvents.payload(fixture("ticket-spend-cap-reached.v1.json")),
        104,
        spend_identity,
        "5693",
        source: %{kind: :legacy, name: "spend_cap"},
        occurred_at: ~U[2026-10-24 20:01:00Z],
        observed_at: ~U[2026-10-24 20:01:00Z]
      )

    cancel_identity = identity("5698")

    cancel_result =
      external(
        "ticket.5698.cancel.result",
        fixture("ticket-cancel.v1.json") |> CancellationOutboundEvents.payload(),
        105,
        cancel_identity,
        nil,
        occurred_at: ~U[2026-10-23 12:00:00Z],
        observed_at: ~U[2026-10-23 12:00:00Z]
      )

    assert with_seq(lifecycle, 1) == fixture("ticket-lifecycle-event.v1.json")
    assert with_seq(progress, 2) == fixture("ticket-progress-event.v1.json")
    assert with_seq(usage, 3) == fixture("ticket-usage-event.v1.json")
    assert with_seq(spend_cap, 4) == fixture("ticket-spend-cap-reached-event.v1.json")
    assert with_seq(cancel_result, 5) == fixture("ticket-cancel-result-event.v1.json")
  end

  test "selects supported canonical records and skips gaps or other exported topics" do
    record = fixture("ticket-lifecycle-event.v1.json") |> Map.put("type", "event")

    assert {:ok, event} = Event.webhook_event(record)
    refute Map.has_key?(event, "type")
    assert Event.delivery_id(event) == {:ok, "host/default/101"}
    assert :skip = Event.webhook_event(%{"type" => "gap", "seq" => 1})

    assert :skip =
             Event.webhook_event(%{
               "type" => "event",
               "instance" => "host/default",
               "id" => 1,
               "topic" => "ticket.5695.pr.merged"
             })
  end

  defp external(topic, payload, id, identity, run_id, opts \\ []) do
    source = Keyword.get(opts, :source, %{kind: :legacy, name: "outbound_source"})
    occurred_at = Keyword.get(opts, :occurred_at, @observed_at)
    observed_at = Keyword.get(opts, :observed_at, @observed_at)

    event =
      payload
      |> Map.merge(%{id: id, topic: topic})
      |> Map.put(:ticket_observation, observation(identity, id, source, run_id, occurred_at, observed_at))

    assert {:ok, external} = Envelope.to_external(event, instance: "host/default")
    external
  end

  defp observation(identity, event_id, source, run_id, occurred_at, observed_at) do
    %TicketObservation{
      status: :joinable,
      reason: nil,
      tracker_identity: identity,
      source: source,
      event_id: event_id,
      provenance: %{run_id: run_id},
      occurred_at: occurred_at,
      observed_at: observed_at,
      attributes: %{}
    }
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  defp with_seq(event, seq), do: Map.put(event, "seq", seq)

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
