defmodule Aiur.UsageLedger.OutboundEvents do
  @moduledoc false

  alias Aiur.Events.Outbound.Producer
  alias Aiur.{TrackerIdentity, UsageEnvelope}
  alias Aiur.UsageEnvelope.ExactMoney

  @token_fields [:input, :cached_input, :cache_creation_input, :output, :reasoning_output, :provider_reported_total]

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
  def payload(acknowledgement), do: %{outbound_event: %{kind: :ticket_usage, data: usage_data(acknowledgement)}}

  defp usage_data(acknowledgement) do
    %{
      "position" => acknowledgement.position,
      "generation" => acknowledgement.generation,
      "delta" => %{
        "tokens" => Map.new(@token_fields, fn field -> {Atom.to_string(field), Map.get(acknowledgement.delta.tokens, field)} end),
        "cost" => money(acknowledgement.delta.cost),
        "source_version" => acknowledgement.delta.source_version,
        "relationship_revision" => acknowledgement.delta.relationship_revision,
        "coverage_reasons" => Enum.map(acknowledgement.delta.coverage_reasons, &Atom.to_string/1)
      }
    }
  end

  defp money(nil), do: nil

  defp money(%ExactMoney{} = money) do
    money
    |> ExactMoney.to_map()
    |> Map.take(["amount", "currency", "unit", "measurement_kind", "counter_scope", "source", "source_version"])
  end
end
