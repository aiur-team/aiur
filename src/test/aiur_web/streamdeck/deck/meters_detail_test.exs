defmodule AiurWeb.Streamdeck.Deck.MetersDetailTest do
  use ExUnit.Case, async: false
  alias Aiur.TestSupport.BuildHome.UsageInputs, as: I
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Streamdeck.Deck.{Input, Meters, Nav}
  alias AiurWeb.Streamdeck.Render.MeterDetail

  defp detail(accounts, overrides \\ %{}) do
    inputs = I.inputs(Map.merge(%{families: [:claude], accounts: accounts}, overrides))
    EndpointStubs.put(streamdeck_usage_load_fun: fn :streamdeck, _opts -> inputs end)
    Meters.detail("claude", now: I.now())
  end

  test "accounts sort by name and keep independent reset times and stale values" do
    personal = I.account(50, 30)
    work = I.account(88, 60) |> Map.put(:freshness, :stale)
    work = put_in(work, [:reading, :windows, Access.at(0), :resets_at], DateTime.add(I.now(), 7200))
    result = detail(%{"work" => work, "personal" => personal})
    assert Enum.map(result.accounts, & &1.name) == ["personal", "work"]
    [personal, work] = result.accounts
    assert personal.session == %{remaining_percent: 50, reset_at: DateTime.to_unix(DateTime.add(I.now(), 3600), :millisecond), freshness: "fresh"}
    assert work.session == %{remaining_percent: 12, reset_at: DateTime.to_unix(DateTime.add(I.now(), 7200), :millisecond), freshness: "stale"}
    assert work.weekly.remaining_percent == 40
    assert work.freshness == "stale"
    image = MeterDetail.key(work, DateTime.to_unix(I.now(), :millisecond))
    assert image.svg =~ "12% left · 2h"
    assert image.svg =~ "stale"
    assert image.svg =~ "0.45"
  end

  test "missing weekly observation remains nil and renders a hatch with a dash" do
    entry = update_in(I.account(50, 30), [:reading, :windows], &Enum.take(&1, 1))
    result = detail(%{"personal" => entry})
    assert [account] = result.accounts
    assert account.weekly == %{remaining_percent: nil, reset_at: nil, freshness: "fresh"}
    image = MeterDetail.key(account, DateTime.to_unix(I.now(), :millisecond))
    assert image.svg =~ "— · —"
    assert image.svg =~ "unknown-hatch"
    assert length(Regex.scan(~r/data-part="remaining-fill"/, image.svg)) == 1
    frame = MeterDetail.frame(result, %{"summary_label" => "personal · closest of 1"}, DateTime.to_unix(I.now(), :millisecond))
    assert length(frame.keys) == 8
    assert Enum.count(frame.keys, & &1) == 1
    assert hd(frame.strip).label == "claude · personal · closest of 1"
  end

  test "single-account provider uses its own observation and ages it with the shared cutoff" do
    entry = I.account(88, nil) |> Map.put(:observed_at, DateTime.add(I.now(), -86_400))
    result = detail(%{"personal" => entry})
    assert [account] = result.accounts
    assert account.name == "personal"
    assert account.session.remaining_percent == 12
    assert account.freshness == "stale"
    assert account.session.freshness == "stale"
  end

  test "single non-Claude provider keeps both semantic windows" do
    inputs = I.inputs(%{meters: %{codex: I.snapshot(:codex, %{"primary" => I.window(88, 300), "secondary" => I.window(30, 10_080)})}})
    EndpointStubs.put(streamdeck_usage_load_fun: fn :streamdeck, _opts -> inputs end)
    assert [account] = Meters.detail("codex", now: I.now()).accounts
    assert account.session.remaining_percent == 12
    assert account.weekly.remaining_percent == 70
  end

  test "resolved Fleet meter key pushes detail, account press is read-only, hold returns" do
    sections = %{{:meter_detail, "claude"} => [%{id: "personal"}], fleet: [%{id: "claude", kind: :meter_detail}]}
    nav = %Nav{view: :fleet, selected: "17"}
    assert {opened, []} = Input.reduce(nav, %{"kind" => "key_press", "index" => 0}, sections)
    assert opened.stack == [{:meter_detail, "claude"}]
    assert {^opened, []} = Input.reduce(opened, %{"kind" => "key_press", "index" => 0}, sections)
    assert {^opened, []} = Input.reduce(opened, %{"kind" => "dial_turn", "index" => 1, "ticks" => -1}, sections)
    assert {closed, []} = Input.reduce(opened, %{"kind" => "dial_long_press", "index" => 3}, sections)
    assert closed.view == :fleet
    assert closed.stack == []
  end
end
