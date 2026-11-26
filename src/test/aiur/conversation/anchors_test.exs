defmodule Aiur.Conversation.AnchorsTest do
  use ExUnit.Case, async: true

  alias Aiur.Conversation.Anchors

  test "an entry exactly at an event's timestamp belongs to that event" do
    entry = %{timestamp: "2026-01-01T10:00:00Z", body: "at boundary"}
    events = [%{id: :event, timestamp: entry.timestamp}]

    assert [%{id: :origin, entries: []}, %{id: :event, entries: [^entry]}] =
             events |> Anchors.with_origin([entry]) |> Anchors.at_or_before([entry])
  end

  test "an event without a timestamp claims nothing" do
    earlier = %{timestamp: "2026-01-01T10:00:01Z"}
    later = %{timestamp: "2026-01-01T10:00:03Z"}
    events = [%{id: :missing, timestamp: nil}, %{id: :recent, timestamp: "2026-01-01T10:00:02Z"}]
    entries = [earlier, later]

    assert [%{id: :origin, entries: [^earlier]}, %{id: :missing, entries: []}, %{id: :recent, entries: [^later]}] =
             events |> Anchors.with_origin(entries) |> Anchors.at_or_before(entries)
  end

  test "an entry without a timestamp falls to the origin" do
    missing = %{timestamp: nil, body: "unattributed"}
    dated = %{timestamp: "2026-01-01T10:00:01Z"}
    events = [%{id: :event, timestamp: "2026-01-01T10:00:00Z"}]
    entries = [missing, dated]

    assert [%{id: :origin, entries: [^missing]}, %{id: :event, entries: [^dated]}] =
             events |> Anchors.with_origin(entries) |> Anchors.at_or_before(entries)
  end

  test "emit and consumed twins have distinct identities" do
    assert Anchors.event_identity("emit", 7) == {:bus, "emit", 7}
    assert Anchors.event_identity("consumed", 7) == {:bus, "consumed", 7}
    assert Anchors.event_identity(nil, 7) == {:bus, nil, 7}
  end

  test "instants are compared parsed, not lexically" do
    entry = %{timestamp: "2026-01-01T10:00:00.5Z"}
    events = [%{id: :event, timestamp: "2026-01-01T10:00:00Z"}]

    assert [%{entries: []}, %{id: :event, entries: [^entry]}] =
             events |> Anchors.with_origin([entry]) |> Anchors.at_or_before([entry])
  end

  test "with no events, the origin holds every entry" do
    dated = %{timestamp: "2026-01-01T10:00:00Z"}
    missing = %{timestamp: nil}
    entries = [dated, missing]

    assert [%{id: :origin, timestamp: "2026-01-01T10:00:00Z", entries: [^missing, ^dated]}] =
             [] |> Anchors.with_origin(entries) |> Anchors.at_or_before(entries)
  end

  test "origin is neutral and uses the earliest stringified timestamp across both feeds" do
    event = %{id: :event, timestamp: ~U[2026-01-01 10:00:00Z]}
    entry = %{timestamp: "2026-01-01T09:00:00Z"}
    assert Anchors.origin_id() == :origin
    assert Anchors.with_origin([event], [entry]) == [%{id: :origin, timestamp: "2026-01-01 10:00:00Z"}, event]
    assert Anchors.with_origin([], []) == [%{id: :origin, timestamp: nil}]
  end

  test "unparseable timestamps keep the lexical fallback and entries before the event" do
    earlier = %{timestamp: "a"}
    boundary = %{timestamp: "b"}
    later = %{timestamp: "c"}
    events = [%{id: :event, timestamp: "b"}]
    entries = [earlier, boundary, later]

    assert [%{entries: [^earlier]}, %{id: :event, entries: [^boundary, ^later]}] =
             events |> Anchors.with_origin(entries) |> Anchors.at_or_before(entries)
  end
end
