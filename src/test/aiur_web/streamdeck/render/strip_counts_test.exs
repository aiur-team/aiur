defmodule AiurWeb.Streamdeck.Render.StripCountsTest do
  use ExUnit.Case, async: true

  alias AiurWeb.Streamdeck.Render.StripCounts

  test "orders positive agent categories and keeps the backlog separate" do
    counts = counts(%{"active" => 9, "ci_wait" => 2, "command" => 1, "error" => 0})
    model = StripCounts.model(counts)

    assert model.status == "ok"
    assert state_counts(model.chips) == [%{state: "command", count: 1}, %{state: "active", count: 9}, %{state: "ci_wait", count: 2}]
    assert model.visible == model.chips
    assert Enum.map(model.chips, & &1.glyph) == ["!", "▶", "◷"]
    assert model.more == 0
    assert model.backlog == %{queued: 512, not_queued: 17}
    assert Enum.sum(Enum.map(model.chips, & &1.count)) == counts.agents
    assert StripCounts.model(Jason.decode!(Jason.encode!(counts))) == model
  end

  test "nil counts are omitted and make the band unavailable instead of zero" do
    model = StripCounts.model(counts(%{"active" => 2, "command" => nil, "paused" => 0}))
    assert model.status == "unavailable"
    assert state_counts(model.chips) == [%{state: "active", count: 2}]
    assert StripCounts.model(nil).status == "unavailable"
    assert StripCounts.model(nil).backlog == %{queued: nil, not_queued: nil}
  end

  test "eleven states reserve the eighth slot for four more and a tick advances the window" do
    states = ~w(error command retrying active ci_wait usage_limited parked paused blocked merge-queued unknown)
    counts = counts(Map.new(states, &{&1, 1}))
    first = StripCounts.model(counts)
    next = StripCounts.model(counts, 1)

    assert Enum.map(first.visible, & &1.state) == Enum.take(states, 7)
    assert first.more == 4
    assert next.offset == 1
    assert Enum.map(next.visible, & &1.state) == Enum.slice(states, 1, 7)
    assert next.more == 4
    assert state_counts(StripCounts.model(counts, 999).visible) == Enum.take(states, -7) |> Enum.map(&%{state: &1, count: 1})
    assert StripCounts.model(counts, -1).visible == first.visible
    assert StripCounts.model(counts(Map.new(Enum.take(states, 8), &{&1, 1})), 1).more == 0
  end

  test "stale counts retain their values and unrecognized categories contribute to unknown" do
    counts = %{counts(%{"mystery" => 3, "unknown" => 2, "blocked" => 1, "active" => 4}) | status: "stale"}
    model = StripCounts.model(counts)

    assert model.status == "stale"
    assert state_counts(model.chips) == [%{state: "active", count: 4}, %{state: "blocked", count: 1}, %{state: "unknown", count: 5}]
    assert Enum.sum(Enum.map(model.chips, & &1.count)) == counts.agents
    assert model.backlog == %{queued: 512, not_queued: 17}
    assert StripCounts.model(%{counts | status: "unavailable"}).status == "unavailable"
  end

  defp state_counts(chips), do: Enum.map(chips, &Map.take(&1, [:state, :count]))

  defp counts(by_state) do
    %{status: "ok", agents: by_state |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum(), by_state: by_state, queued: 512, not_queued: 17}
  end
end
