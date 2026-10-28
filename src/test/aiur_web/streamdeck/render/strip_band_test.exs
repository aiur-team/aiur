defmodule AiurWeb.Streamdeck.Render.StripBandTest do
  use ExUnit.Case, async: true
  alias Aiur.BuildOrder.TicketStatus
  alias AiurWeb.Streamdeck.{Deck, Render}
  alias AiurWeb.Streamdeck.Deck.{Input, Nav}
  alias AiurWeb.Streamdeck.Render.{StripBand, StripCounts, Style}

  test "shared taxonomy supplies labels, face colors and glyphs for every category" do
    states = TicketStatus.agent_states()
    model = StripCounts.model(counts(Map.new(states, &{&1, 1})))
    assert length(model.chips) == length(states)

    for chip <- model.chips do
      status = TicketStatus.encode(%{sec: "now", agent: %{state: chip.state}})
      assert chip.label == status.label
      assert chip.color == Style.state(status.tone).accent
      refute chip.glyph in [nil, "?"]
    end

    assert Style.agent("mystery") == %{label: "State unknown", glyph: "?", color: Style.state(:unknown).accent}
  end

  test "raw dial tick changes the rendered overflow window and shrink clamps it" do
    states = ~w(error command retrying active ci_wait usage_limited parked paused blocked merge-queued unknown)
    grid = %{agents: [], counts: counts(Map.new(states, &{&1, 1}))}
    input = %{"kind" => "dial_turn", "index" => 1, "ticks" => 1}
    {nav, []} = Input.reduce(%Nav{}, input, Deck.navigation(grid))
    assert nav.chip_offset == 1
    before = Render.frame(%{grid: grid, nav: %Nav{}}).strip |> Enum.at(1)
    after_tick = Render.frame(%{grid: grid, nav: nav}).strip |> Enum.at(1)
    assert before.svg =~ ~s(data-state="error")
    refute after_tick.svg =~ ~s(data-state="error")
    assert after_tick.svg =~ ~s(data-state="paused")
    assert after_tick.svg =~ "+4 more"
    refute before.hash == after_tick.hash

    smaller = %{grid | counts: counts(%{"active" => 1})}
    {nav, []} = Input.reduce(nav, input, Deck.navigation(smaller))
    assert nav.chip_offset == 0
    {selected, [{:priority, "42", :down, 1}]} = Input.reduce(%{nav | selected: "42"}, input, Deck.navigation(grid))
    assert selected.chip_offset == 0
    {cycled, []} = Input.reduce(selected, %{"kind" => "dial_press", "index" => 3}, Deck.navigation(grid))
    {scrolled, []} = Input.reduce(cycled, input, Deck.navigation(grid))
    assert scrolled.selected == nil
    assert scrolled.chip_offset == 1
  end

  test "large fleets keep nine pager dots around the current page and clamp at each end" do
    model = StripCounts.model(counts(%{"active" => 1}))

    for {offset, pages, selected} <- [{0, Enum.to_list(0..8), 0}, {36, Enum.to_list(5..13), 9}, {999, Enum.to_list(9..17), 17}] do
      svg = StripBand.backlog(%{model: model, offset: offset, total: 144}) |> IO.iodata_to_binary()
      assert Regex.scan(~r/data-page="(\d+)"/, svg, capture: :all_but_first) |> Enum.map(fn [page] -> String.to_integer(page) end) == pages
      assert svg =~ ~s(fill="#9fd0ff" data-page="#{selected}")
    end
  end

  test "stale chips are dimmed and unavailable counts never render a plausible zero" do
    counts = counts(%{"active" => 9})
    [_, chips, backlog] = Render.frame(%{counts: %{counts | status: "stale"}}).strip
    assert chips.svg =~ ~s(opacity="0.45")
    assert chips.svg =~ "Agents · stale"
    assert chips.svg =~ "▶ 9"
    assert backlog.svg =~ "Queued 512"
    assert backlog.svg =~ "Not queued 17"

    [_, unavailable, backlog] = Render.frame(%{counts: %{counts | by_state: %{"active" => nil}, queued: nil, not_queued: nil}}).strip
    assert unavailable.label == "Counts unavailable"
    assert unavailable.svg =~ "Counts unavailable"
    refute unavailable.svg =~ "▶"
    assert backlog.svg =~ "Queued unknown"
    refute backlog.svg =~ "Queued 0"
  end

  test "count strip matches the SVG fixture rasterized by the PNG golden test" do
    frame = Render.frame(%{counts: counts(%{"active" => 9, "ci_wait" => 2, "command" => 1})})
    svg = Enum.map_join(frame.strip, fn image -> "<g transform=\"translate(#{image.x},0)\">#{image.svg}</g>" end)
    svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"800\" height=\"100\">#{svg}</svg>"
    assert svg == File.read!(Path.expand("../../../fixtures/streamdeck/strip-counts.svg", __DIR__))
  end

  defp counts(by_state), do: %{status: "ok", agents: 12, by_state: by_state, queued: 512, not_queued: 17}
end
