defmodule AiurWeb.Streamdeck.Deck.InputTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck
  alias AiurWeb.Streamdeck.Deck.{Input, Nav}

  test "resolves feature, epic and fleet keys from sections, then their child tickets" do
    for view <- [:feature, :epic, :fleet] do
      sections = %{view => [%{id: "group", tickets: [%{id: "6030"}]}]}
      nav = %Nav{view: view}
      frame = %{"kind" => "key_press", "index" => 0, "target" => ["ticket", "forged"]}
      {nav, []} = Input.reduce(nav, frame, sections)
      assert nav.stack == [{view, "group"}]
      {nav, [{:open_ticket, "6030"}]} = Input.reduce(nav, frame, sections)
      assert nav.selected == "6030"
      assert {^nav, []} = Input.reduce(nav, %{frame | "index" => 7}, sections)
      {nav, []} = Input.reduce(nav, %{"kind" => "dial_long_press", "index" => 3}, sections)
      assert nav.stack == []
    end
  end

  test "clamps before resolving a key after a list shrinks" do
    sections = %{ticket: Enum.map(1..9, &%{id: to_string(&1)})}
    nav = %Nav{pages: %{ticket: 3, feature: 0, epic: 0, fleet: 0}}
    {nav, [{:open_ticket, "9"}]} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    assert Nav.page(nav) == 1
  end

  test "Deck sections retain ordered tickets and provide filtered fleet drills" do
    fleet = %{keys: [%{id: "active", cat: :active, states: ["active"], tickets: [%{id: "1"}, %{id: "3"}]}]}
    grid = %{fleet: fleet, agents: [%{identifier: "1", bucket: :running}, %{identifier: "2", bucket: :paused}, %{identifier: "3", bucket: :running}]}
    sections = Deck.navigation(grid)
    assert Enum.map(sections.ticket, & &1.id) == ["1", "2", "3"]
    assert Enum.map(sections.fleet, & &1.id) == ["active"]
    nav = %Nav{view: :fleet}
    {nav, []} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    {nav, [{:open_ticket, "3"}]} = Input.reduce(nav, %{"kind" => "key_press", "index" => 1}, sections)
    assert nav.selected == "3"
  end
end
