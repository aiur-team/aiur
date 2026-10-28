defmodule AiurWeb.Streamdeck.Deck.FleetTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Fleet, Input, Nav, Tickets}
  alias AiurWeb.Streamdeck.Render

  test "categories partition the Ticket population, including unknown, duplicates and unfiled rows" do
    window = window()
    fleet = read(window)
    deck = Deck.read(window: {:ok, window}, now_ms: 10_000, global_pause: true)
    assert deck.fleet == fleet
    assert deck.counts.agents == 9
    assert deck.counts.queued == 3
    assert deck.counts.live == 1
    assert Enum.sum(Enum.map(Enum.take(fleet.keys, 7), & &1.count)) == deck.counts.agents + deck.counts.queued
    assert Enum.map(fleet.keys, & &1.count) == [2, 1, 2, 1, 1, 2, 3, nil]
    assert Enum.sum(Enum.map(Enum.take(fleet.keys, 7), & &1.count)) == length(Tickets.keys(window.sections))
    assert hd(fleet.keys).unknown == 1
    assert hd(fleet.keys).label == "2 · 1?"
    assert Render.key(hd(fleet.keys)).svg =~ "2 · 1?"
    assert List.last(fleet.keys).label == "9 / —"
    assert Enum.map(List.last(fleet.keys).tickets, & &1.id) == ~w(3 2 4 1 5 6 7 8 9)
    assert {capacity_nav, []} = Input.reduce(%Nav{view: :fleet}, %{"kind" => "key_press", "index" => 7}, Deck.navigation(%{fleet: fleet}))
    assert capacity_nav.stack == [{:state, [:live]}]
    assert Enum.map(Enum.at(fleet.keys, 2).tickets, & &1.state) == ["error", "retrying"]
    assert Enum.map(Enum.at(fleet.keys, 5).tickets, & &1.state) == ["parked", "paused"]
  end

  test "wire categories preserve canonical state filters and physical key positions" do
    fleet = window() |> read() |> Jason.encode!() |> Jason.decode!()
    {nav, []} = Input.reduce(%Nav{view: :fleet}, %{"kind" => "key_press", "index" => 7}, Deck.navigation(%{"fleet" => fleet}))
    assert nav.stack == [{:state, [:live]}]
    frame = Render.frame(%{grid: %{"fleet" => fleet}, nav: nav})
    assert hd(frame.keys).svg =~ "Ticket 3"
    root = Render.frame(%{grid: %{"fleet" => fleet}, nav: %Nav{view: :fleet}})
    assert Enum.at(root.keys, 5).svg =~ "Waiting for CI"
  end

  test "unknown capacity and stale heartbeat survive into the rendered frame with their values" do
    fleet = read(window())
    assert fleet.strip.capacity_max == nil
    assert fleet.strip.capacity_stale == true
    assert fleet.strip.daemon == "stale"
    assert fleet.strip.heartbeat_age_s == 7
    assert fleet.strip.global_pause == true
    frame = Render.frame(%{grid: %{fleet: fleet}, nav: %Nav{view: :fleet}})
    assert List.last(frame.keys).svg =~ "9 / —"
    assert Enum.at(frame.strip, 0).svg =~ "stale 7s"
    assert Enum.at(frame.strip, 1).svg =~ "Capacity — stale"
    assert Enum.at(frame.strip, 2).svg =~ "Global pause: on"
  end

  test "CI key pushes the state filter and opens exactly a CI ticket through navigation" do
    fleet = read(window())
    sections = Deck.navigation(%{fleet: fleet, agents: Tickets.keys(window().sections)})
    assert {nav, []} = Input.reduce(%Nav{view: :fleet}, %{"kind" => "key_press", "index" => 3}, sections)
    assert nav.stack == [{:state, ["ci_wait"]}]
    frame = Render.frame(%{grid: %{fleet: fleet}, nav: nav})
    assert hd(frame.keys).label =~ "Waiting for CI"
    assert Enum.drop(frame.keys, 1) == List.duplicate(nil, 7)
    assert {%Nav{selected: "5"}, [{:open_ticket, "5"}]} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
  end

  test "unavailable remains unknown, while measured capacity and live heartbeat render as observed" do
    assert Fleet.read(window: {:error, :offline}).status == "unavailable"
    unavailable = window() |> put_in([:sources, :agents, :state], "unavailable") |> read()
    assert unavailable.status == "unavailable"
    assert unavailable.keys == []
    unavailable_frame = Render.frame(%{grid: %{fleet: unavailable}, nav: %Nav{view: :fleet}})
    assert hd(unavailable_frame.keys).svg =~ "Fleet unavailable"
    data = window() |> put_in([:capacity, :max], 24) |> put_in([:daemon, :state], "live")
    frame = Render.frame(%{grid: %{fleet: read(data)}, nav: %Nav{view: :fleet}})
    assert List.last(frame.keys).svg =~ "9 / 24"
    assert hd(frame.strip).svg =~ "live 7s"
  end

  defp read(window), do: Fleet.read(window: {:ok, window}, now_ms: 10_000, global_pause: true)

  defp window do
    now = Enum.with_index(~w(active command error retrying ci_wait usage_limited parked paused mystery), 1) |> Enum.map(fn {s, n} -> row(n, s) end)
    plan = Enum.map(10..12, &Map.merge(row(&1, nil), %{sec: "plan", agent: nil, qpos: &1}))

    %{
      sources: %{agents: %{state: "ok"}},
      sections: %{now: now ++ [%{num: nil}, hd(now)], plan: plan ++ [hd(now)], nq: []},
      capacity: %{max: nil, stale: true},
      daemon: %{state: "stale", heartbeat_at: 3_000}
    }
  end

  defp row(n, state), do: %{num: n, id: to_string(n), sec: "now", title: "Ticket #{n}", agent: %{state: state}}
end
