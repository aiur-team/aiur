defmodule Aiur.CurrentRunMembership.OutboundEvents do
  @moduledoc false

  alias Aiur.CurrentRunMembership.Event
  alias Aiur.Events.Outbound.Producer

  @spec publish(Event.t(), pos_integer()) :: :ok
  def publish(%Event{} = event, _generation) do
    topic = "ticket.#{event.identity.identifier}.lifecycle.changed"
    Producer.maybe_publish(topic, payload(event), event.identity, event.run_id, event.observed_at)
  end

  @doc false
  @spec payload(Event.t()) :: map()
  def payload(%Event{} = event) do
    %{
      outbound_event: %{
        kind: :ticket_lifecycle,
        data: %{
          "lifecycle" => Atom.to_string(event.lifecycle),
          "source" => Atom.to_string(event.source),
          "observed_at" => DateTime.to_iso8601(event.observed_at)
        }
      }
    }
  end
end
