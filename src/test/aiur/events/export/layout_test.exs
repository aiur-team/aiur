defmodule Aiur.Events.Export.LayoutTest do
  use ExUnit.Case, async: true
  alias Aiur.Events.Envelope
  alias Aiur.Events.Export.Layout

  test "replay validator rejects incomplete envelopes and fields outside the external schema" do
    {:ok, envelope} = Envelope.to_external(%{id: 1, topic: "ticket.42.pr.merged"}, instance: "test/instance")
    record = Map.merge(envelope, %{"type" => "event", "seq" => 1})
    assert Layout.validate(record) == {:ok, record}

    for key <- Map.keys(envelope) do
      assert {:error, :invalid_record} = Layout.validate(Map.delete(record, key))
    end

    assert {:error, :invalid_record} = Layout.validate(Map.put(record, "body", "private text"))
    assert {:error, :invalid_record} = Layout.validate(Map.put(record, "observed_at", "yesterday"))
  end
end
