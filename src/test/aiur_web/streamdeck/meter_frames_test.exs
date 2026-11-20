defmodule AiurWeb.Streamdeck.MeterFramesTest do
  use AiurWeb.StreamdeckChannelCase
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias AiurWeb.Streamdeck.Deck.{Meters, Nav}
  alias AiurWeb.Streamdeck.FrameUpdates

  test "shared frame composition retains account navigation and leaves focused surfaces available" do
    now = DateTime.utc_now()
    entry = I.account(38, nil) |> Map.put(:observed_at, now)
    entry = update_in(entry, [:reading, :windows], &Enum.map(&1, fn window -> %{window | resets_at: DateTime.add(now, 7200)} end))
    inputs = I.inputs(%{families: [:claude], accounts: %{"personal" => entry}})
    put_endpoint_config(streamdeck_usage_load_fun: fn _, _ -> inputs end)
    usage = Meters.read()
    grid = Map.put(StreamdeckProjection.grid(), :meter_usage, usage)
    nav = Enum.reduce(1..3, %Nav{}, fn _, nav -> transition(nav, grid, "press") end)
    {:ok, nav, [:close_ticket]} = FrameUpdates.transition(nav, %{"kind" => "dial", "index" => 3, "action" => "turn", "delta" => 1}, grid)
    {:ok, nav, []} = FrameUpdates.transition(nav, %{"kind" => "key", "index" => 0, "action" => "down"}, grid)
    assert nav.stack == [{:meter_detail, "claude"}]
    {same, model, frame} = FrameUpdates.frame(nav, grid, usage)
    assert same.stack == nav.stack
    assert same.meter_count == 1
    assert model.nav == same
    assert [%{name: "personal", session: %{remaining_percent: 62}, weekly: %{remaining_percent: nil}}] = model.grid.meter_detail.accounts
    assert hd(frame.keys).svg =~ "62% left"
    assert hd(frame.keys).svg =~ "unknown-hatch"
    {_nav, _model, focused} = FrameUpdates.frame(%{same | surface: :settings}, grid, usage)
    assert length(focused.keys) == 8
    assert hd(focused.keys).label == "Mic · Unavailable"
    assert hd(focused.keys).svg =~ "Mic"
    {:ok, closed, [:close_ticket]} = FrameUpdates.transition(nav, %{"kind" => "dial", "index" => 3, "action" => "long_press"}, grid)
    assert closed.stack == []
    {_nav, _model, back} = FrameUpdates.frame(closed, grid, usage)
    assert hd(back.keys).svg =~ "claude usage"
  end

  defp transition(nav, grid, action) do
    {:ok, nav, [:close_ticket]} = FrameUpdates.transition(nav, %{"kind" => "dial", "index" => 3, "action" => action}, grid)
    nav
  end
end
