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
      lifecycle: Atom.to_string(event.lifecycle),
      lifecycle_source: Atom.to_string(event.source)
    }
  end
end
