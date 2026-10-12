defmodule AiurWeb.OperatorControlCenter.ModelsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.ModelsPanel

  @now ~U[2026-07-20 12:00:00Z]

  defp render(cards), do: render_component(&ModelsPanel.models_panel/1, %{cards: cards, now: @now})

  defp card(provider, windows, extra \\ %{}) do
    Map.merge(%{provider: provider, provider_label: String.capitalize(to_string(provider)), logo: "/#{provider}.svg", windows: windows}, extra)
  end

  defp window(limit_id, name, percent, seconds_to_reset, extra \\ %{}) do
    Map.merge(
      %{kind: :rate_limit, limit_id: limit_id, name: name, meter: %{kind: :exact, now: percent}, used_percent: percent, resets_at: DateTime.add(@now, seconds_to_reset, :second)},
      extra
    )
  end

  defp account(name, percent, seconds_to_reset) do
    %{name: name, percent: percent, freshness: :fresh, age_seconds: 15, resets_at: seconds_to_reset && DateTime.add(@now, seconds_to_reset, :second)}
  end

  test "a reset reads as the time, its window and the recycle icon, never 'resets in'" do
    html = render([card(:codex, [window("codex:primary", "Primary", 62, 5 * 86_400 + 4 * 3_600 + 59 * 60, %{duration_minutes: 10_080})])])

    assert html =~ ~s(<span class="rs-pc">62%</span>)
    assert html =~ "5d 4h<em>/7d</em>"
    assert html =~ ~s(<path d="M20 11a8 8 0 0 0-14.8-3.5)
    refute html =~ "resets in"
    refute html =~ "Primary</span>"
    refute html =~ "rs-tg"
  end

  test "each account keeps its own named line and the provider-wide weekly window is not repeated" do
    accounts = [account("default", 0.0, 2 * 86_400), account("everdred", 12.0, 6 * 86_400 + 15 * 3_600)]

    windows = [
      window("claude:five_hour", "Session (5 hour)", 9.5, 4 * 3_600 + 2 * 60),
      window("claude:seven_day", "Weekly (all models)", 12.0, 6 * 86_400 + 15 * 3_600)
    ]

    html = render([card(:claude, windows, %{account_usage: %{count: 2, accounts: accounts}, summary_label: "worst of 2 accounts · everdred"})])

    assert html =~ ~s(<span class="rs-x" title="2 accounts">×2</span>)
    assert html =~ ~s(data-account="default")
    assert html =~ ~s(<span class="rs-tg">everdred</span>)
    assert html =~ ~s(<span class="rs-tg">session</span>)
    assert html =~ "4h 2m<em>/5h</em>"
    assert html =~ "6d 15h<em>/7d</em>"
    assert html =~ "--rs-tag-width: 8ch"
    refute html =~ "Weekly"
    refute html =~ "worst of"
    refute html =~ "fresh ·"
    refute html =~ "s old</span>"
  end

  test "prepaid credits show the spend percentage and the balance" do
    credits = %{kind: :credit, name: "Credits", used_percent: 2.3, credits: %{amount: 10.4, status: :available}}
    html = render([card(:deepseek, [credits])])

    assert html =~ ~s(<span class="rs-pc">2%</span>)
    assert html =~ ~s(<b class="rs-usd">$10.40</b>)
    assert html =~ ~s(style="width:2.3%")
  end

  test "a real provider with nothing observed reads unknown, never zero" do
    html = render([card(:codex, [])])

    assert html =~ ~s(<span class="rs-no">unknown</span>)
    assert html =~ "rs-meter is-unknown"
    refute html =~ "0%"
    refute html =~ "Limits"
    refute html =~ "Not observed"
  end

  test "a durable last-known standing renders its percentage with a red bar at 100%" do
    html = render([card(:codex, [], %{durable_observation: %{percent: 100}})])

    assert html =~ ~s(<span class="rs-pc is-critical">100%</span>)
    assert html =~ ~s(class="is-critical" style="width:100%")
  end

  test "percentages are whole numbers that never round up to a full window" do
    html = render([card(:codex, [window("codex:primary", "Primary", 99.6, 60), window("codex:secondary", "Secondary", 0.4, 60)])])

    assert html =~ ">99%</span>"
    assert html =~ "&lt;1%</span>"
    refute html =~ ">100%</span>"
  end
end
