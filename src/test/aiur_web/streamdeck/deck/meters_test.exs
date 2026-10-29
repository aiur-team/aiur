defmodule AiurWeb.Streamdeck.Deck.MetersTest do
  use ExUnit.Case, async: false
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.Meters

  defp read(inputs) do
    load = fn :streamdeck, opts ->
      assert opts[:meter_source] == AiurWeb.Build.RedactedMeterSource
      inputs
    end

    EndpointStubs.put(streamdeck_usage_load_fun: load)
    Meters.read(now: I.now())
  end

  defp inputs(accounts) do
    I.inputs(%{families: [:claude], meters: %{claude: I.snapshot(:claude, %{"five_hour" => I.window(50), "seven_day" => I.window(30)})}, accounts: accounts})
  end

  test "selects one closest account across both windows using Build remaining readings" do
    meter = read(inputs(%{"personal" => I.account(50, 30), "work" => I.account(88, 60)}))["claude"]
    assert meter["summary_label"] == "work · closest of 2"
    assert meter["windows"]["session"] == %{"remaining_percent" => 12, "used_percent" => 88, "freshness" => "fresh", "resets_at" => DateTime.to_iso8601(DateTime.add(I.now(), 3600))}
    assert meter["windows"]["weekly"]["remaining_percent"] == 40
    assert meter["state"] == "observed"
    assert meter["freshness"] == "fresh"
  end

  test "a single Claude account keeps its name with the Build reading" do
    meter = read(inputs(%{"work" => I.account(50, 30)}))["claude"]
    assert meter["summary_label"] == "work · closest of 1"
    assert meter["windows"]["session"]["remaining_percent"] == 50
  end

  test "ties use account names and weekly can select the closest account" do
    meter = read(inputs(%{"z" => I.account(5, 95), "a" => I.account(95, 1)}))["claude"]
    assert meter["summary_label"] == "a · closest of 2"
    assert meter["windows"]["weekly"]["remaining_percent"] == 99
    meter = read(inputs(%{"z" => I.account(5, 96), "a" => I.account(95, 1)}))["claude"]
    assert meter["summary_label"] == "z · closest of 2"
    assert meter["windows"]["session"]["remaining_percent"] == 95
  end

  test "partial accounts name observation count and preserve nil instead of zero" do
    meter = read(inputs(%{"a" => %{reading: nil, observed_at: I.now()}, "work" => I.account(nil, 60)}))["claude"]
    assert meter["summary_label"] == "work · 1/2 observed"
    assert meter["windows"]["session"]["remaining_percent"] == nil
    assert meter["windows"]["session"]["used_percent"] == nil
    assert meter["windows"]["weekly"]["remaining_percent"] == 40
  end

  test "credit providers retain the Build percentage without inventing a reset" do
    credit = I.window(25, nil, %{kind: :credit, credits: %{status: :available, amount: 10}, remaining: 10})
    meter = read(I.inputs(%{families: [:deepseek], meters: %{deepseek: I.snapshot(:deepseek, %{"balance" => credit})}}))["deepseek"]
    assert meter["windows"] == %{"session" => %{"remaining_percent" => 75, "used_percent" => 25, "resets_at" => nil, "freshness" => "fresh"}}
    assert meter["state"] == "observed"
  end

  test "Build unavailable rows have no windows and carry their reason and freshness" do
    unknown = I.inputs(%{meters: %{codex: Aiur.ProviderMeterSnapshot.unknown(:codex, :app_server)}, durable: %{codex: %{percent: 42, observed_at: I.now()}}})
    meter = read(unknown)["codex"]
    assert meter["state"] == "unknown"
    assert meter["windows"] == %{}
    assert meter["reason"] == "Last known 58% left (previous boot)"
    assert meter["freshness"] == "stale"
  end
end
