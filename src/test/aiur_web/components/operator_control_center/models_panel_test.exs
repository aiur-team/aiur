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
      %{kind: :rate_limit, limit_id: limit_id, name: name, meter: %{kind: :exact, now: 100 - percent}, used_percent: percent, resets_at: DateTime.add(@now, seconds_to_reset, :second)},
      extra
    )
  end

  defp account(name, percent, seconds_to_reset) do
    %{name: name, percent: percent, freshness: :fresh, age_seconds: 15, resets_at: seconds_to_reset && DateTime.add(@now, seconds_to_reset, :second)}
  end

  test "a reset reads as the time, its window and the recycle icon, never 'resets in'" do
    html = render([card(:codex, [window("codex:primary", "Primary", 62, 5 * 86_400 + 4 * 3_600 + 59 * 60, %{duration_minutes: 10_080})])])

    assert html =~ ~s(<span class="rs-pc">38% left</span>)
    assert html =~ ~s(style="width:38%")
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

  test "each window has its own full-width meter track" do
    html =
      render([
        card(:claude, [
          window("claude:five_hour", "Session (5 hour)", 7, 2 * 3_600, %{duration_minutes: 300}),
          window("claude:seven_day", "Weekly (7 day)", 67, 86_400, %{duration_minutes: 10_080})
        ])
      ])

    assert length(Regex.scan(~r/class="rs-ln"/u, html)) == 2
    assert length(Regex.scan(~r/class="rs-meter"/u, html)) == 2
    assert html =~ "93% left"
    assert html =~ "33% left"
    assert html =~ "2h 0m<em>/5h</em>"
    assert html =~ "1d 0h<em>/7d</em>"
  end

  test "prepaid credits show the remaining percentage and the balance" do
    credits = %{kind: :credit, name: "Credits", used_percent: 2.3, credits: %{amount: 10.4, status: :available}}
    html = render([card(:deepseek, [credits])])

    assert html =~ ~s(<span class="rs-pc">98% left</span>)
    assert html =~ ~s(<b class="rs-usd">$10.40</b>)
    assert html =~ ~s(style="width:97.7%")
  end

  test "a real provider with nothing observed reads unknown, never zero" do
    html = render([card(:codex, [])])

    assert html =~ ~s(<span class="rs-no">unknown</span>)
    assert html =~ "rs-meter is-unknown"
    refute html =~ ~s(<i style="width:0%"></i>)
    refute html =~ "0%"
    refute html =~ "Limits"
    refute html =~ "Not observed"
  end

  test "remaining bars map 0, 50 and 100 percent used to full, half and empty and unknown stays unknown" do
    html =
      render([
        card(:codex, [window("zero", "Zero", 0, 60), window("half", "Half", 50, 60), window("full", "Full", 100, 60), %{kind: :rate_limit, name: "Unknown", used_percent: nil}])
      ])

    assert html =~ ~s(style="width:100%")
    assert html =~ ~s(style="width:50%")
    assert html =~ ~s(class="rs-meter is-unknown")
    assert html =~ ~s(<span class="rs-pc">100% left</span>)
    assert html =~ ~s(<span class="rs-pc">50% left</span>)
    assert html =~ ~s(<span class="rs-pc is-critical">0% left</span>)
    assert html =~ "unknown"
  end

  test "provider presenter meter values already mean remaining and are not converted twice" do
    html = render([card(:codex, [window("primary", "Primary", 40, 60, %{remaining_percent: 60, meter: %{kind: :exact, now: 60}})])])

    assert html =~ ~s(<span class="rs-pc">60% left</span>)
    assert html =~ ~s(style="width:60%")
  end

  test "Codex headroom uses the dispatch value and visibly includes its age" do
    html = render([card(:codex, [], %{headroom: %{status: :observed, remaining_percent: 74, age_seconds: 75}})])

    assert html =~ ~s(<span class="rs-pc">74% left</span>)
    assert html =~ "74% left · 75s old"
    assert html =~ "74% remaining · observed 75s ago"
    refute html =~ ~s(class="rs-no">unknown</span>)
  end

  test "stale Codex headroom stays unknown and displays the reason and age" do
    html =
      render([
        card(:codex, [], %{
          headroom: %{status: :stale, reason: "Last headroom reading is stale", age_seconds: 1900}
        })
      ])

    assert html =~ "Last headroom reading is stale · 1900s old"
    assert html =~ "rs-ln has-tag is-stale"
    refute html =~ ~s(<span class="rs-pc">0% left</span>)
  end

  # #5747: the session window read 81% for 3.6 hours with no mark. Account
  # and window lines on one card share one cutoff
  # (`agent.headroom_reading_max_age_seconds`, 1800 s by default), so a
  # reading never shows current on one line and stale on the line below.
  test "account and window lines on one card share the stale cutoff" do
    for {age, stale?} <- [{1_200, false}, {13_000, true}] do
      observed_at = DateTime.add(@now, -age, :second)
      freshness = if stale?, do: :stale, else: :fresh
      account = Map.merge(account("default", 40, 86_400), %{freshness: freshness, age_seconds: age})
      session = window("claude:five_hour", "Session (5 hour)", 81, 3_600, %{observed_at: observed_at})

      html = render([card(:claude, [session], %{account_usage: %{count: 1, accounts: [account]}})])

      marks = Regex.scan(~r/class="rs-ln[^"]*is-stale"/, html)
      assert length(marks) == if(stale?, do: 2, else: 0), "age #{age}s"
    end
  end

  # A cached re-serve under the cutoff is what `aiur accounts` calls
  # `cached`, not `stale`; the panel must not dim it either.
  test "a cached account line under the cutoff is not dimmed" do
    cached = Map.merge(account("default", 40, 86_400), %{freshness: :cached, last_error: :rate_limited})

    html = render([card(:claude, [], %{account_usage: %{count: 1, accounts: [cached]}})])

    refute html =~ "is-stale"
    assert html =~ "cached, 15s old · last error rate_limited"
  end

  test "a failing account line is stale and names the last probe error" do
    failing = Map.merge(account("default", nil, nil), %{freshness: :stale, age_seconds: 13_000, last_error: :rate_limited})

    html = render([card(:claude, [], %{account_usage: %{count: 1, accounts: [failing]}})])

    assert html =~ ~r/class="rs-ln has-tag is-stale" data-account="default"/
    assert html =~ "13000s old · last error rate_limited"
  end

  test "a durable last-known standing renders an empty bar at zero percent remaining" do
    html = render([card(:codex, [], %{durable_observation: %{percent: 100}})])

    assert html =~ ~s(<span class="rs-pc is-critical">0% left</span>)
    assert html =~ ~s(<span class="rs-meter" role="progressbar" aria-label="Last known remaining" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">)
  end

  test "percentages are whole numbers that never round up to a full window" do
    html = render([card(:codex, [window("codex:primary", "Primary", 99.6, 60), window("codex:secondary", "Secondary", 0.4, 60)])])

    assert html =~ "&lt;1% left</span>"
    assert html =~ ">100% left</span>"
    refute html =~ ">100%</span>"
  end
end
