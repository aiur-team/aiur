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

  # An unknown ticket count is a head-row stat with no row of its own, so an
  # empty one is noise. Progress and Limits each own a labelled row and a meter,
  # so they keep their N/A — dropping those would leave a card that looks like
  # it has nothing to report at all.
  test "an unknown ticket count is hidden, while progress and limits keep their N/A" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    refute html =~ "Tickets"

    assert html =~ "Progress"
    assert html =~ "Limits"
    assert html =~ "N/A"
  end

  test "a known ticket count is shown" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :empty, counts: %{remaining: 0}, progress: %{}},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    assert html =~ "Tickets"
    assert html =~ "0 remain"
  end

  # Codex reports an account-wide limit alongside per-model ones. Only the
  # account-wide bucket governs whether work can proceed, and a row per model
  # turns a glanceable card into a table.
  test "only the account-wide rate limit is shown, not per-model ones" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          windows: [
            scoped_window("codex:primary", 12),
            scoped_window("codex_bengalfox:primary", 88)
          ]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "12%"
    refute html =~ "88%"
  end

  test "falls back to whatever exists when no account-wide window is reported" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          windows: [scoped_window("codex_bengalfox:primary", 88)]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "88%"
  end

  # A prepaid balance is a :credit window with no percentage. It must render as
  # a dollar amount, never as a fabricated "0% consumed" bar, and stay visible
  # next to any rate-limit window the provider also publishes.
  test "renders a credit balance window as a dollar amount" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :deepseek,
          provider_label: "DeepSeek",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [
            %{
              kind: :credit,
              name: :credits,
              coverage_label: "Supported",
              credits: %{status: :available, label: "Available", amount: 7.25},
              expires_at: DateTime.add(@now, 5, :minute)
            },
            scoped_window("local-concurrency", 0)
          ]
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "$7.25"
    refute html =~ "0% consumed"
  end

  # A provider that has never been observed this boot reads :unknown — a bare
  # N/A — even when the durable dispatch-limits ledger holds its last standing.
  # The strip must degrade to that durable record with an explicit staleness
  # label instead of rendering an empty card.
  test "renders the durable last-known standing with a staleness label" do
    observed_at = ~U[2026-08-02 08:53:00Z]
    dir = Path.join(System.tmp_dir!(), "aiur-strip-durable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    workflow_path = Path.join(dir, ".aiurconfig")

    previous_path = Application.get_env(:aiur, :workflow_file_path)

    try do
      Application.put_env(:aiur, :workflow_file_path, workflow_path)

      :ok =
        Aiur.ModelAvailability.observe(
          "codex",
          %{weekly: %{used: 100, limit: 100, reset_at: DateTime.add(@now, 86_400, :second) |> DateTime.to_iso8601()}},
          now: observed_at
        )

      meters = %{
        state: :authorized,
        cards: [
          %{
            provider: :codex,
            provider_label: "Codex",
            state: :unknown,
            status_label: "",
            auth_mode: %{value: :subscription},
            windows: []
          }
        ]
      }

      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: %{state: :loading},
          usage: %{state: :ready, providers: %{}},
          meters: meters,
          now: @now
        })

      assert html =~ "100% used · as of 08:53 UTC"
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
  end

  test "keeps N/A for a provider with no durable record either" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :deepseek,
          provider_label: "DeepSeek",
          state: :unknown,
          status_label: "",
          auth_mode: %{value: :api_key},
          windows: []
        }
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })

    assert html =~ "N/A"
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

  # Mirrors the shape ProviderMetersPresenter emits: the rendered percentage
  # comes from `meter.now`, and `coverage_label` is required by the meta
  # renderer.
  defp scoped_window(limit_id, percent) do
    %{
      limit_id: limit_id,
      kind: :rate_limit,
      name: "Primary",
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent},
      resets_at: DateTime.add(@now, 30, :minute)
    }
  end

  defp restore_app_env(app, key, previous) do
    if is_nil(previous) do
      Application.delete_env(app, key)
    else
      Application.put_env(app, key, previous)
    end
  end
end
