defmodule Aiur.UsageLedger.OutboundEvents do
  @moduledoc false

  alias Aiur.Events.Outbound.Producer
  alias Aiur.{TrackerIdentity, UsageEnvelope}

  @spec publish(UsageEnvelope.t(), map()) :: :ok
  def publish(%UsageEnvelope{} = envelope, acknowledgement) do
    identity = envelope.attribution.tracker_identity

    if TrackerIdentity.joinable?(identity) do
      topic = "ticket.#{identity.identifier}.usage.changed"
      Producer.maybe_publish(topic, payload(acknowledgement), identity, envelope.attribution.run_id, envelope.occurred_at)
    else
      :ok
    end
  end

  @doc false
  @spec payload(map()) :: map()
  def payload(acknowledgement), do: %{position: acknowledgement.position, generation: acknowledgement.generation}
end
