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

  test "the shared envelope builds all five webhook contract families" do
    identity = identity()
    lifecycle_fixture = fixture("ticket-lifecycle-event.v1.json")
    progress_fixture = fixture("ticket-progress-event.v1.json")
    usage_fixture = fixture("ticket-usage-event.v1.json")
    spend_cap_fixture = fixture("ticket-spend-cap-reached-event.v1.json")
    cancel_result_fixture = fixture("ticket-cancel-result-event.v1.json")

    {:ok, membership} =
      MembershipEvent.new("run-5695-1", identity, :running, timestamp(lifecycle_fixture, "observed_at"), source: :tracker)

    lifecycle =
      external(
        "ticket.5695.lifecycle.changed",
        MembershipOutboundEvents.payload(membership),
        101,
        identity,
        "run-5695-1",
        lifecycle_fixture
      )

    progress =
      external(
        "ticket.5695.agent.progress.checkin",
        %{percent: 40, progress_source: "progress.checkin"},
        102,
        identity,
        "run-5695-1",
        progress_fixture,
        source: %{kind: :agent_event, name: "progress.checkin"}
      )

    usage =
      external(
        "ticket.5695.usage.changed",
        UsageOutboundEvents.payload(%{position: 17, generation: 17}),
        103,
        identity,
        "run-5695-1",
        usage_fixture
      )

    spend_identity = identity("5693")

    spend_cap =
      external(
        "ticket.5693.usage.spend_cap_reached",
        SpendCapOutboundEvents.payload(fixture("ticket-spend-cap-reached.v1.json")),
        104,
        spend_identity,
        "5693",
        spend_cap_fixture,
        source: %{kind: :legacy, name: "spend_cap"}
      )

    cancel_identity = identity("5698")

    cancel_result =
      external(
        "ticket.5698.cancel.result",
        fixture("ticket-cancel.v1.json") |> CancellationOutboundEvents.payload(),
        105,
        cancel_identity,
        nil,
        cancel_result_fixture
      )

    assert with_seq(lifecycle, 1) == lifecycle_fixture
    assert with_seq(progress, 2) == progress_fixture
    assert with_seq(usage, 3) == usage_fixture
    assert with_seq(spend_cap, 4) == spend_cap_fixture
    assert with_seq(cancel_result, 5) == cancel_result_fixture
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

  test "exports only requested and answered decision topics" do
    assert Event.exportable_topic?("ticket.5695.agent.decision.requested")
    assert Event.exportable_topic?("ticket.5695.agent.decision.answered")
    refute Event.exportable_topic?("ticket.5695.agent.decision.executor-acknowledged")
  end

  defp external(topic, payload, id, identity, run_id, expected, opts \\ []) do
    source = Keyword.get(opts, :source, %{kind: :legacy, name: "outbound_source"})
    occurred_at = timestamp(expected, "occurred_at")
    observed_at = timestamp(expected, "observed_at")

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

  defp timestamp(fixture, field) do
    {:ok, timestamp, 0} = fixture |> Map.fetch!(field) |> DateTime.from_iso8601()
    timestamp
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
