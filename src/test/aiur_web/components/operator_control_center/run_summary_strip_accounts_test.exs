defmodule AiurWeb.OperatorControlCenter.RunSummaryStripAccountsTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{ProviderMetersPresenter, RunSummaryStrip}

  @now ~U[2026-07-20 12:00:00Z]

  test "an unavailable account renders unknown rather than zero usage" do
    readings = %{
      "default" => %{reading: %{windows: [%{window: "seven_day", used_percent: 94.0}]}, freshness: :fresh, observed_at: @now},
      "offline" => %{reading: nil, freshness: :unavailable, observed_at: nil}
    }

    meters = ProviderMetersPresenter.present(%{state: :authorized}, %{}, readings)
    claude = Enum.find(meters.cards, &(&1.provider == :claude))
    offline = Enum.find(claude.account_usage.accounts, &(&1.name == "offline"))
    assert offline.percent == nil
    assert claude.account_usage.total_percent == nil

    html = render_component(&RunSummaryStrip.run_summary_strip/1, %{run: %{state: :ready}, usage: %{state: :ready, providers: %{}}, meters: meters, now: @now})
    [row] = html |> Floki.parse_fragment!() |> Floki.find("[data-provider=claude] [data-account=offline]")
    assert Floki.text(row) =~ "unknown"
    # Freshness lives in the line's tooltip, not in repeated row text (#3751).
    assert row |> Floki.attribute("title") |> hd() =~ "unavailable"
    refute Floki.text(row) =~ "unavailable"
    refute Floki.text(row) =~ "0%"
    assert Floki.attribute(Floki.find(row, "[role=progressbar]"), "aria-valuenow") == []
    assert Floki.find(row, "i") == []
  end
end
