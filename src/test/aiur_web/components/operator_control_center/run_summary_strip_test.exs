defmodule AiurWeb.OperatorControlCenter.RunSummaryStripTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-20 12:00:00Z]

  test "renders real run, per-provider usage, and rate-limit values" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    assert html =~ "4 remain"
    assert html =~ "$8.75"
    assert html =~ "20m elapsed"
    assert html =~ "About 8m remaining"
    assert html =~ "1.5K"
    assert html =~ "$2.50"
    assert html =~ "40% · resets in 30m"
    refute html =~ "$50.47"
    refute html =~ "0.89M"

    # The Live stat was dropped: it duplicated what the Units table already
    # shows, and the extra column pushed the head row past the card's edge at
    # the narrow end of the grid.
    refute html =~ ~s(<span class="rs-stat-label">Live</span>)
    refute html =~ "3 units"
  end

  test "names unavailable values instead of presenting synthetic zeroes" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    assert html =~ "N/A"
    refute html =~ "ETA unavailable"
    assert html =~ "Codex"
    assert html =~ "Claude"
    refute html =~ "$0.00"

    # Still no synthetic zeroes: a count that genuinely is not known must not
    # borrow the empty run's "0".
    refute html =~ "0 remain"
  end

  # `:empty` is the presenter's confirmed "no active Aiur run" — the daemon
  # answered, and the answer is zero. Rendering that as "Unavailable" told
  # operators something was broken when nothing was.
  test "an empty run reads as a real zero, not as unavailable" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :empty, counts: %{remaining: 0}, progress: %{}},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    assert html =~ "0 remain"
    assert html =~ "0% · no active run"
    assert html =~ ~s(<i style="width:0%">)
  end

  test "hides spend for subscription accounts" do
    meters =
      update_in(meters_view(), [:cards], fn cards ->
        Enum.map(cards, fn
          %{provider: :codex} = card -> put_in(card, [:auth_mode, :value], :subscription)
          card -> card
        end)
      end)

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters,
        now: @now
      })

    [codex_html, claude_html] = String.split(html, "Claude", parts: 2)
    refute codex_html =~ "$2.50"
    assert claude_html =~ "$6.25"
  end

  test "hides aggregate spend unless at least one provider uses an API key" do
    subscription_meters =
      update_in(meters_view(), [:cards], fn cards ->
        Enum.map(cards, &put_in(&1, [:auth_mode, :value], :subscription))
      end)

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: subscription_meters,
        now: @now
      })

    refute html =~ "Spend"
    refute html =~ "$8.75"
  end

  test "omits the zero-eligible-weight ETA filler" do
    run = put_in(run_view(), [:eta], %{reason: :zero_eligible_weight, label: "Unavailable — no eligible weight"})

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run,
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    refute html =~ "no eligible weight"
  end

  defp run_view do
    %{
      state: :ready,
      counts: %{live: 3, remaining: 4},
      progress: %{kind: :exact, percent: 60},
      elapsed: %{label: "20m"},
      eta: %{label: "About 8m remaining"}
    }
  end

  defp usage_view do
    %{
      state: :ready,
      api_equivalent: %{by_currency: [%{currency: "USD", amount: "8.75"}]},
      providers: %{
        codex: %{tokens: %{total: 1_500}, api_equivalent: [%{currency: "USD", amount: "2.50"}]},
        claude: %{tokens: %{total: 2_000}, api_equivalent: [%{currency: "USD", amount: "6.25"}]}
      }
    }
  end

  defp meters_view do
    %{
      state: :authorized,
      cards: [
        meter_card(:codex, "Codex", 40),
        meter_card(:claude, "Claude", 25)
      ]
    }
  end

  defp meter_card(provider, label, percent) do
    %{
      provider: provider,
      provider_label: label,
      status_label: "Healthy",
      auth_mode: %{value: :api_key},
      windows: [
        %{
          kind: :rate_limit,
          name: "Session",
          coverage_label: "Supported",
          meter: %{kind: :exact, now: percent},
          resets_at: DateTime.add(@now, 30, :minute)
        }
      ]
    }
  end
end
