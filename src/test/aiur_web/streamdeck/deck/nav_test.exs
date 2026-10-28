defmodule AiurWeb.Streamdeck.Deck.NavTest do
  use ExUnit.Case, async: true
  alias AiurWeb.Streamdeck.Deck.Nav

  @sizes %{ticket: 30, feature: 24, epic: 16, fleet: 8, drill: 30}

  test "cycles all views, clears drills and preserves each root page" do
    nav = struct!(Nav, pages: %{ticket: 2, feature: 1, epic: 1, fleet: 0})
    {cycled, []} = step(nav, "dial_press", 3)
    assert cycled.view == :feature
    assert Nav.page(cycled) == 1
    {cycled, []} = step(cycled, "dial_press", 3)
    assert cycled.view == :epic
    {cycled, []} = step(cycled, "dial_press", 3)
    assert cycled.view == :fleet
    {cycled, []} = step(cycled, "dial_press", 3)
    assert cycled == nav
  end

  test "pages by detent, clamps before stepping and after list shrink" do
    {nav, []} = step(struct!(Nav), "dial_turn", 3, 3)
    assert Nav.page(nav) == 3
    assert {^nav, []} = step(nav, "dial_turn", 3, 1)
    {shrunk, []} = Nav.reduce(nav, %{"kind" => "dial_press", "index" => 0}, %{@sizes | ticket: 9})
    assert Nav.page(shrunk) == 1
    {back, []} = Nav.reduce(nav, %{"kind" => "dial_turn", "index" => 3, "ticks" => -1}, %{@sizes | ticket: 9})
    assert Nav.page(back) == 0
  end

  test "drills into a feature then opens a ticket and restores root paging on back" do
    nav = struct!(Nav, view: :feature, pages: %{ticket: 0, feature: 1, epic: 0, fleet: 0})
    input = %{"kind" => "key_press", "index" => 0, target: {:feature, "feature-a"}}
    {drilled, []} = Nav.reduce(nav, input, @sizes)
    assert drilled.stack == [{:feature, "feature-a"}]
    assert Nav.page(drilled) == 0
    {paged, []} = step(drilled, "dial_turn", 3, 2)
    assert Nav.page(paged) == 2
    {opened, [{:open_ticket, "6030"}]} = Nav.reduce(paged, %{input | target: {:ticket, "6030"}}, @sizes)
    assert opened.selected == "6030"
    {back, []} = step(opened, "dial_long_press", 3)
    assert back.stack == []
    assert Nav.page(back) == 1
    assert {^back, []} = step(back, "dial_long_press", 3)
    {cycled, []} = step(drilled, "dial_press", 3)
    assert cycled.stack == []
    assert cycled.view == :epic
  end

  test "priority, scroll, reserved press and local dial semantics" do
    nav = struct!(Nav)
    assert {^nav, []} = step(nav, "dial_turn", 1, -2)
    selected = %{nav | selected: "6030"}
    assert {^selected, [{:priority, "6030", :up, 2}]} = step(selected, "dial_turn", 1, -2)
    assert {^selected, [{:priority, "6030", :down, 3}]} = step(selected, "dial_turn", 1, 3)
    assert {^selected, []} = step(selected, "dial_turn", 1, 0)

    for kind <- ["dial_press", "dial_long_press", "dial_turn"] do
      assert {^selected, []} = step(selected, kind, 2, 4)
    end

    {scrolled, []} = step(nav, "dial_turn", 0, 5)
    assert scrolled.scroll == 5
    {scrolled, []} = step(scrolled, "dial_turn", 0, -8)
    assert scrolled.scroll == 0
    assert {^nav, []} = step(nav, "dial_press", 0)
  end

  test "rejects unknown kinds, malformed indexes and turn ticks" do
    for input <- [
          %{"kind" => "bogus", "index" => 0},
          %{"kind" => "key_press", "index" => 8},
          %{"kind" => "dial_press", "index" => -1},
          %{"kind" => "dial_press", "index" => 4},
          %{"kind" => "dial_turn", "index" => 0, "ticks" => 33},
          %{"kind" => "dial_turn", "index" => 0},
          %{"kind" => "dial_turn", "index" => 0, "ticks" => 1.5}
        ] do
      assert {:error, %{reason: "invalid_input"}} = Nav.reduce(struct!(Nav), input, @sizes)
    end
  end

  defp step(nav, kind, index, ticks \\ 0), do: Nav.reduce(nav, %{"kind" => kind, "index" => index, "ticks" => ticks}, @sizes)
end
