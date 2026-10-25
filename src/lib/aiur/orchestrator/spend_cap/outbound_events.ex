defmodule Aiur.Orchestrator.SpendCap.OutboundEvents do
  @moduledoc false

  alias Aiur.Events

  @spec publish(function(), String.t(), map(), pos_integer(), Aiur.TrackerIdentity.t()) :: term()
  def publish(fun, topic, payload, event_id, identity) when is_function(fun, 4),
    do: fun.(topic, payload, event_id, identity)

  def publish(fun, topic, payload, event_id, _identity) when is_function(fun, 3),
    do: fun.(topic, payload, event_id)

  @spec publish(String.t(), map(), pos_integer(), Aiur.TrackerIdentity.t()) :: term()
  def publish(topic, payload, event_id, identity) do
    Events.publish_persisted(topic, payload, event_id,
      digest_source: :orchestrator,
      identity: identity,
      observation_source: %{kind: :legacy, name: "spend_cap"},
      observation_provenance: %{run_id: payload["job_id"]},
      occurred_at: parse_datetime(payload["reached_at"])
    )
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
