defmodule AiurWeb.Streamdeck.Deck.MetersAPIsTest do
  use ExUnit.Case, async: false
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.{Meters, Nav}
  alias AiurWeb.Streamdeck.FrameUpdates

  test "Build quota readings reach the Fleet model as remaining with GraphQL held" do
    usage = read(%{github: {:ok, I.quota(3950, 400)}, meters: %{codex: I.snapshot(:codex, %{"primary" => I.window(21, 300)})}})
    {_, model, frame} = FrameUpdates.frame(%Nav{view: :fleet}, %{agents: []}, usage)
    assert [%{name: "GitHub", stale: false, observed_at: observed, lines: [core, gql]}] = model.usage["apis"]
    assert observed == DateTime.to_unix(I.now(), :millisecond)
    assert core.remaining_percent == 79
    assert gql.remaining_percent == 8
    assert gql.hold_until == DateTime.to_unix(DateTime.add(I.now(), 3600), :millisecond)
    assert core.tip == "Requests left: 3,950 of 5,000 · 79% left"
    svg = Enum.at(frame.strip, 2).svg
    assert svg =~ "core 79% left"
    assert svg =~ "gql 8% ⏸ held until 13:00"
    assert svg =~ ~s(width="142.2")
    assert Enum.at(frame.strip, 1).svg =~ "codex 79% left"
    {_, _, scrolled} = FrameUpdates.frame(%Nav{view: :fleet, scroll: 999}, %{agents: []}, usage)
    assert Enum.at(scrolled.strip, 1) == Enum.at(frame.strip, 1)
  end

  test "unconfigured ElevenLabs is absent from the model and Fleet bars" do
    usage = read(%{elevenlabs: %{state: :unconfigured}})
    {_, model, frame} = FrameUpdates.frame(%Nav{view: :fleet}, %{agents: []}, usage)
    assert Enum.map(model.usage["apis"], & &1.name) == ["GitHub"]
    svg = Enum.at(frame.strip, 2).svg
    refute svg =~ "ElevenLabs"
    refute svg =~ "credits"
  end

  test "unavailable GitHub keeps nil readings and renders dashes with the reason" do
    usage = read(%{github: {:error, :unavailable}})
    assert [%{name: "GitHub", observed_at: nil, lines: lines}] = usage["apis"]
    assert Enum.map(lines, & &1.remaining_percent) == [nil, nil]
    assert Enum.all?(lines, &String.contains?(&1.tip, "GitHub budget meter unavailable"))
    {_, _, frame} = FrameUpdates.frame(%Nav{view: :fleet}, %{agents: []}, usage)
    svg = Enum.at(frame.strip, 2).svg
    assert svg =~ "core —"
    assert svg =~ "gql —"
    assert svg =~ "GitHub budget meter unavailable"
    refute svg =~ "progress-fill"
    refute svg =~ "0%"
  end

  test "observed ElevenLabs credits and expired GitHub windows retain Build semantics" do
    elevenlabs = %{state: :observed, observed_at: I.now(), window: %{used_percent: 25, remaining: 750, reset_at: DateTime.add(I.now(), 3600)}}
    quota = I.quota(3950, 400)
    quota = %{quota | windows: Map.new(quota.windows, fn {name, window} -> {name, %{window | reset_at: DateTime.add(I.now(), -1)}} end)}
    usage = read(%{github: {:ok, quota}, elevenlabs: elevenlabs})
    assert [%{stale: true, lines: [_, %{hold_until: nil}]}, %{name: "ElevenLabs", lines: [credits]}] = usage["apis"]
    assert credits.remaining_percent == 75
    {_, _, frame} = FrameUpdates.frame(%Nav{view: :fleet}, %{agents: []}, usage)
    svg = Enum.at(frame.strip, 2).svg
    assert svg =~ "E credits 75% left"
    assert svg =~ ~s(opacity="0.45")
    refute svg =~ "held until"
  end

  defp read(overrides) do
    inputs = I.inputs(overrides)
    EndpointStubs.put(streamdeck_usage_load_fun: fn :streamdeck, _opts -> inputs end)
    Meters.read(now: I.now())
  end
end
