defmodule AiurWeb.Streamdeck.Deck.MetersAPIsTest do
  use ExUnit.Case, async: false
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.{Meters, Nav}
  alias AiurWeb.Streamdeck.FrameUpdates

  test "provider enumeration excludes API lists and preserves unknown provider readings" do
    usage = read(%{github: {:error, :unavailable}})
    assert [%{name: "GitHub"}] = usage["apis"]
    assert Meters.providers(usage) == %{"codex" => usage["codex"]}
    assert Meters.providers(Map.put(usage, :apis, usage["apis"])) == %{"codex" => usage["codex"]}
    assert Meters.providers(%{}) == %{}
    assert Meters.providers(%{"codex" => nil, "apis" => []}) == %{"codex" => nil}

    for view <- [:fleet, :epic] do
      {_, model, frame} = FrameUpdates.frame(%Nav{view: view}, %{agents: []}, usage)
      provider_keys = Enum.filter(model.grid.fleet.keys, &match?(%{kind: :meter_detail}, &1))
      assert Enum.map(provider_keys, & &1.id) == ["codex"]
      assert length(frame.keys) == 8
      refute Enum.any?(frame.keys, &(&1 && &1.label == "apis usage"))
    end
  end

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
    assert svg =~ "gql 8% ⏸ until 13:00"
    assert svg =~ ~s(width="142.2")
    assert svg =~ ~r{core 79% left</text>.*0s old}
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
    assert svg =~ "never"
    refute svg =~ "progress-fill"
    refute svg =~ "0%"
  end

  test "observed ElevenLabs credits render while expired GitHub windows show a dash with their age" do
    elevenlabs = %{state: :observed, observed_at: DateTime.add(I.now(), 600), window: %{used_percent: 25, remaining: 750, reset_at: DateTime.add(I.now(), 3600)}}
    quota = I.quota(3950, 400)
    quota = %{quota | windows: Map.new(quota.windows, fn {name, window} -> {name, %{window | reset_at: DateTime.add(I.now(), -1)}} end)}
    usage = read(%{github: {:ok, quota}, elevenlabs: elevenlabs}, DateTime.add(I.now(), 840))
    assert [%{stale: true, age_seconds: 840, lines: [core, %{hold_until: nil}]}, %{name: "ElevenLabs", lines: [credits]}] = usage["apis"]
    assert core.remaining_percent == 79
    assert credits.remaining_percent == 75
    {_, _, frame} = FrameUpdates.frame(%Nav{view: :fleet}, %{agents: []}, usage)
    svg = Enum.at(frame.strip, 2).svg
    assert svg =~ ~r{E credits 75% left</text>.*240s old}
    assert svg =~ "core —"
    assert svg =~ "gql —"
    assert svg =~ "840s old"
    refute svg =~ "core 79%"
    refute svg =~ "gql 8%"
    refute svg =~ "⏸"
  end

  defp read(overrides, now \\ I.now()) do
    inputs = I.inputs(overrides)
    EndpointStubs.put(streamdeck_usage_load_fun: fn :streamdeck, _opts -> inputs end)
    Meters.read(now: now)
  end
end
