defmodule Aiur.CurrentRunMembership.EventTest do
  use ExUnit.Case, async: true

  alias Aiur.CurrentRunMembership.{Event, Event.Codec}
  alias Aiur.TrackerIdentity

  @observed_at ~U[2026-07-14 12:00:00Z]

  test "rejects oversized identity scalars before persistence" do
    identity = identity(owner: String.duplicate("a", 513))

    assert {:error, :identity_too_large} = Event.new("event-size-test", identity, :queued, @observed_at)
  end

  test "enforces a total recovery record size bound" do
    {:ok, event} = Event.new("event-size-test", identity(), :queued, @observed_at)
    record = Map.put(Event.to_record(event), "padding", String.duplicate("x", 4_097))

    assert {:error, :record_too_large} = Codec.validate_recovery_record_size(record)
  end

  defp identity(overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          version: 1,
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "I-event",
          identifier: "42",
          reason: nil
        ],
        overrides
      )
    )
  end
end
