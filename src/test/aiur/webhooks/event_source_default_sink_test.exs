defmodule Aiur.Webhooks.EventSourceDefaultSinkTest do
  use ExUnit.Case, async: true

  alias Aiur.Events.Exchange
  alias Aiur.Webhooks.EventSource

  test "default sink publishes through the Publisher with an event id" do
    topic = "ticket.977.pr.opened"
    Exchange.subscribe(topic)
    event = %{topic: topic, payload: %{number: 977}}

    assert {:ok, ^event} = EventSource.publish(event, [])

    assert_receive {:event, %{id: id, topic: ^topic, ticket_observation: _}}
    assert is_integer(id)
  end
end
