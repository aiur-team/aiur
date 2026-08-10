defmodule AiurWeb.OperatorControlCenter.RunSummaryStripTest do
  # The keyed-card filter reads credential env vars, which are process-global,
  # so these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-20 12:00:00Z]

  setup do
    # Deterministic keyed-filter baseline: these credential env vars start
    # unset in every test; a test opts in via the with_*_key helpers.
    System.delete_env("DEEPSEEK_API_KEY")
    System.delete_env("MOONSHOT_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    System.delete_env("OPENROUTER_MANAGEMENT_KEY")
    :ok
  end

  # OpenAI-compatible providers only occupy strip space when their configured
  # credential env resolves to a non-empty value. These tests exercise those
  # cards, so they set the env in-process and restore it afterwards.
  defp with_deepseek_key(fun) do
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.put_env("DEEPSEEK_API_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("DEEPSEEK_API_KEY", previous)
    end
  end

  defp with_kimi_key(fun) do
    previous = System.get_env("MOONSHOT_API_KEY")
    System.put_env("MOONSHOT_API_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("MOONSHOT_API_KEY", previous)
    end
  end

  defp with_openrouter_key(fun) do
    previous = System.get_env("OPENROUTER_MANAGEMENT_KEY")
    System.put_env("OPENROUTER_MANAGEMENT_KEY", "test-key")

    try do
      fun.()
    after
      restore_env("OPENROUTER_MANAGEMENT_KEY", previous)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  # Phoenix HTML keeps template whitespace between inline elements; collapse
  # runs of whitespace so assertions on element order are not whitespace-fragile.
  defp compact(html), do: html |> String.replace(~r/\s+/, " ")

  test "renders real run, per-provider usage, and rate-limit values" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    # Per-provider tokens read number-first, with the glyph to the right.
    assert html =~ "1.5K"
    assert compact(html) =~ "1.5K <img class=\"rs-token-ic\""
    assert html =~ "$2.50"
    assert html =~ "$6.25"
    assert html =~ "40% · resets in 30m"

    # The Live stat was dropped: it duplicated what the Units table already
    # shows, and the extra column pushed the head row past the card's edge at
    # the narrow end of the grid.
    refute html =~ ~s(<span class="rs-stat-label">Live</span>)
    refute html =~ "3 units"
  end

  test "renders GitHub core and GraphQL quota with reset and coarse ownership" do
    github_quota = %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 3750, limit: 5000, used_percent: 25.0, reset_at: DateTime.add(@now, 30, :minute)},
        "graphql" => %{resource: "graphql", remaining: 500, limit: 5000, used_percent: 90.0, reset_at: DateTime.add(@now, 45, :minute)}
      },
      attribution: [
        %{consumer: "ticket:1670", reads: 8, writes: 2, total: 10},
        %{consumer: "unattributed", reads: 1, writes: 0, total: 1}
      ]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: @now
      })

    assert html =~ "GitHub API"
    assert html =~ "3750/5000 left · resets in 30m"
    assert html =~ "500/5000 left · resets in 45m"
    assert html =~ "9R / 2W"
    assert html =~ "ticket:1670 · 10 requests"
    assert html =~ ~s(class="is-warning" style="width:90.0%")
  end

  test "names an active secondary-limit backoff, which the primary meters cannot show" do
    github_quota = %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 4077, limit: 5000, used_percent: 18.5, reset_at: DateTime.add(@now, 30, :minute)}
      },
      attribution: [],
      backoffs: [%{resource: "core", until: DateTime.add(@now, 45, :second), seconds_remaining: 45}]
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: @now
      })

    # The window still reads healthy — the backoff row is the only thing that
    # explains why calls are being refused.
    assert html =~ "4077/5000 left"
    assert html =~ "Core backoff"
    assert html =~ "Secondary limit · 45s left"
  end

  test "names unavailable values instead of presenting synthetic zeroes" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    # App-server providers always render; keyless OpenAI-compatible providers
    # are omitted entirely.
    assert html =~ "Codex"
    assert html =~ "Claude"
    refute html =~ "Kimi"
    refute html =~ "DeepSeek"
    refute html =~ "OpenRouter"
    refute html =~ "$0.00"

    # A locked usage is an unknown token count: the card keeps its token glyph
    # alone instead of a "Tokens N/A" row, while the Limits row still names the
    # unavailable standing.
    assert html =~ "N/A"
    refute html =~ "Tokens"
    assert html =~ "rs-token-na"
  end

  # The compact run summary is hidden whenever the remaining ticket count is
  # zero or not yet known: there is nothing real for it to say.
  test "an empty run hides the compact summary entirely" do
    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: %{state: :empty, counts: %{remaining: 0}, progress: %{}},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    refute html =~ "rs-summary-compact"
    refute html =~ "0 remain"
    refute html =~ "Summary"
  end

  test "an unknown ticket count hides the compact summary" do
    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: %{state: :loading},
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    refute html =~ "rs-summary-compact"
    refute html =~ "Tickets"
  end

  test "the compact summary shows remaining tickets, progress, and spend when tickets remain" do
    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    assert html =~ "rs-summary-compact"
    assert html =~ "Tickets"
    assert html =~ "4 remain"
    assert html =~ "20m elapsed"
    assert html =~ "About 8m remaining"
    assert html =~ ~s(style="width:60%")
    assert html =~ "Spend"
    assert html =~ "$8.75"
  end

  test "hides aggregate spend unless at least one provider uses an API key" do
    subscription_meters =
      update_in(meters_view(), [:cards], fn cards ->
        Enum.map(cards, &put_in(&1, [:auth_mode, :value], :subscription))
      end)

    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: subscription_meters,
        now: @now
      })

    assert html =~ "4 remain"
    refute html =~ "Spend"
    refute html =~ "$8.75"
  end

  test "omits the zero-eligible-weight ETA filler" do
    run = put_in(run_view(), [:eta], %{reason: :zero_eligible_weight, label: "Unavailable — no eligible weight"})

    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run,
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    refute html =~ "no eligible weight"
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
  # next to any rate-limit window the provider also publishes. The zero-flight
  # concurrency gauge is hidden entirely (it only appears once requests are in
  # flight).
  test "renders a credit balance window as a dollar amount and hides the idle concurrency gauge" do
    with_deepseek_key(fn ->
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
      # Only the credit row renders: the idle concurrency gauge is dropped, so
      # exactly one provider limit row survives instead of two. The GitHub
      # quota card has its own row earlier in the strip.
      [_before_provider, provider_html] = String.split(html, "DeepSeek", parts: 2)
      assert length(Regex.scan(~r/<div class="rs-limit">/, provider_html)) == 1
      refute html =~ "concurrency"
    end)
  end

  test "shows the local-concurrency gauge once requests are in flight" do
    with_deepseek_key(fn ->
      meters = %{
        state: :authorized,
        cards: [
          %{
            provider: :deepseek,
            provider_label: "DeepSeek",
            state: :ready,
            status_label: "Healthy",
            auth_mode: %{value: :api_key},
            windows: [scoped_window("local-concurrency", 42)]
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

      assert html =~ "42%"
      assert html =~ ~s(<i class="" style="width:42%">)
    end)
  end

  # A few in-flight requests against a large concurrency limit round to a 0%
  # meter, but the gauge is real activity and must still render. The hide rule
  # keys on the used (in-flight) value, not the rounded meter.
  test "the concurrency gauge stays visible for small in-flight counts that round to 0%" do
    with_deepseek_key(fn ->
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
                limit_id: "local-concurrency",
                kind: :rate_limit,
                name: "Primary",
                coverage_label: "Supported",
                meter: %{kind: :exact, now: 0, min: 0, max: 100},
                used: 5,
                used_percent: 0.2,
                resets_at: DateTime.add(@now, 30, :minute)
              }
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

      # The gauge row still renders (its bar rounds to 0% width, but the row
      # is real activity, not an idle zero).
      assert html =~ ~s(<div class="rs-meter">)
    end)
  end

  # A prepaid balance with a durable baseline renders a real spend percentage
  # alongside the dollar amount: a real bar plus a "Y% used" meta.
  test "a credit window with a baseline renders the spend percentage and the dollar amount" do
    with_deepseek_key(fn ->
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
                used_percent: 1.9,
                credits: %{status: :available, label: "Available", amount: 49.05},
                expires_at: DateTime.add(@now, 5, :minute)
              }
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

      assert html =~ "$49.05 · 1.9% used"
      # The bar renders the measured spend percentage itself (1.9% used), not an
      # empty 0%: the probe attaches `used_percent` without a separate `meter`
      # key, and the strip reads it directly.
      assert html =~ ~s(<i class="" style="width:1.9%">)
    end)
  end

  # Rule 9: an exhausted prepaid balance bar (100% used) renders red.
  test "an exhausted prepaid balance bar renders red" do
    with_deepseek_key(fn ->
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
                used_percent: 100.0,
                credits: %{status: :exhausted, label: "Exhausted", amount: 0},
                expires_at: DateTime.add(@now, 5, :minute)
              }
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

      assert html =~ "$0 · 100% used"
      assert html =~ ~s(class="is-critical" style="width:100.0%")
    end)
  end

  # A credit window whose freshness horizon has passed is not a current reading:
  # it names its observation time and marks itself stale instead of presenting
  # the balance as live (issue #1550).
  test "a credit window past its freshness horizon renders an explicit stale label" do
    with_deepseek_key(fn ->
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
                observed_at: DateTime.add(@now, -6, :minute),
                expires_at: DateTime.add(@now, -1, :minute)
              }
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

      assert html =~ "$7.25 · as of 11:54 UTC (stale)"
      refute html =~ "resets in"
    end)
  end

  # The regression: a balance observed more than four minutes ago (within the
  # final minute of its 300s freshness horizon, or past it) must not render as a
  # fresh current value. The measured spend percentage keeps its row; the meta
  # gains the explicit staleness label.
  test "a credit balance observed more than four minutes ago renders stale, not current" do
    with_deepseek_key(fn ->
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
                used_percent: 1.9,
                credits: %{status: :available, label: "Available", amount: 49.05},
                observed_at: DateTime.add(@now, -270, :second),
                expires_at: DateTime.add(@now, 30, :second)
              }
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

      assert html =~ "$49.05 · 1.9% used · as of 11:55 UTC (stale)"
      # The stale meta is not followed by the fresh "resets in" countdown; the
      # balance is presented with its age, not as a current reading.
      refute html =~ "· resets in"
    end)
  end

  # A provider that has never been observed this boot reads :unknown — a bare
  # N/A — even when the durable dispatch-limits ledger holds its last standing.
  # The strip must degrade to that durable record with an explicit staleness
  # label instead of rendering an empty card. A fully-consumed durable record
  # also turns the bar red.
  test "renders the durable last-known standing with a staleness label and red-at-100 bar" do
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
      assert html =~ ~s(class="is-critical" style="width:100%")
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
  end

  test "keeps N/A for a provider with no durable record either" do
    with_deepseek_key(fn ->
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
    end)
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

  # Rule 2: a provider card is omitted unless that provider is keyed. App-server
  # providers (codex, claude) always render; OpenAI-compatible providers render
  # only when their credential env is set.
  test "omits OpenAI-compatible cards without a configured API key" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :kimi,
          provider_label: "Kimi",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [scoped_window("provider-throughput", 10)]
        },
        %{
          provider: :deepseek,
          provider_label: "DeepSeek",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [scoped_window("local-concurrency", 5)]
        },
        %{
          provider: :openrouter,
          provider_label: "OpenRouter",
          state: :ready,
          status_label: "Healthy",
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

    refute html =~ "Kimi"
    refute html =~ "DeepSeek"
    refute html =~ "OpenRouter"
  end

  test "renders keyed OpenAI-compatible cards" do
    with_kimi_key(fn ->
      with_deepseek_key(fn ->
        with_openrouter_key(fn ->
          meters = %{
            state: :authorized,
            cards: [
              %{
                provider: :kimi,
                provider_label: "Kimi",
                state: :ready,
                status_label: "Healthy",
                auth_mode: %{value: :api_key},
                windows: [scoped_window("provider-throughput", 10)]
              },
              %{
                provider: :deepseek,
                provider_label: "DeepSeek",
                state: :ready,
                status_label: "Healthy",
                auth_mode: %{value: :api_key},
                windows: [scoped_window("local-concurrency", 5)]
              },
              %{
                provider: :openrouter,
                provider_label: "OpenRouter",
                state: :ready,
                status_label: "Healthy",
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

          assert html =~ "Kimi"
          assert html =~ "DeepSeek"
          assert html =~ "OpenRouter"
        end)
      end)
    end)
  end

  # Rule 3: DeepSeek leads the strip — it sorts ahead of the registry card
  # order (codex, claude, kimi, openrouter).
  test "DeepSeek is the first provider card" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: %{state: :loading},
            usage: %{state: :ready, providers: %{}},
            meters: meters_view() |> Map.put(:cards, [card(:codex), card(:claude), card(:deepseek), card(:kimi)]),
            now: @now
          })

        {deepseek_pos, _} = :binary.match(html, "DeepSeek")
        {codex_pos, _} = :binary.match(html, "Codex")
        assert deepseek_pos < codex_pos
      end)
    end)
  end

  # Rule 4: each card renders its own registry logo. The ticket's "swap the
  # Codex and Claude logos" premise was verified false on review — the asset
  # files (`codex-color.svg` is the Codex mark, `claude-symbol.svg` is
  # Anthropic's) and every other surface already pair codex→codex-color and
  # claude→claude-symbol, so the strip keeps the truthful pairing.
  test "renders each card's own registry logo" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters_view(),
        now: @now
      })

    [_, codex_card, claude_card | _] = String.split(html, ~s(<div class="rs-block">))
    assert codex_card =~ "/provider-assets/codex-color.svg"
    refute codex_card =~ "/provider-assets/claude-symbol.svg"
    assert claude_card =~ "/provider-assets/claude-symbol.svg"
    refute claude_card =~ "/provider-assets/codex-color.svg"
  end

  # Rule 6: an unknown token count hides the label and the "N/A", leaving the
  # token glyph alone at logo size in the top-right head stats.
  test "an unknown token count renders the token glyph alone" do
    usage = %{state: :ready, providers: %{codex: %{}, claude: %{}}}

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: usage,
        meters: meters_view(),
        now: @now
      })

    refute html =~ "Tokens"
    refute html =~ ~s(<span class="rs-stat-label">Tokens</span>)
    assert html =~ ~s(<img class="rs-logo rs-token-na" src="/provider-assets/codex-token.svg")
    assert html =~ ~s(<img class="rs-logo rs-token-na" src="/provider-assets/claude-token.svg")
  end

  # Rule 9: any meter at exactly 100% used renders red, including rate-limit
  # windows and the run progress bar.
  test "a rate-limit bar at 100% used renders red" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [scoped_window("codex:primary", 100)]
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

    assert html =~ ~s(class="is-critical" style="width:100%")
  end

  test "a non-critical bar at 99% used stays default" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [scoped_window("codex:primary", 99)]
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

    assert html =~ ~s(<i class="" style="width:99%">)
    refute html =~ "is-critical"
  end

  test "the run progress bar at 100% renders red in the compact summary" do
    run = %{
      state: :ready,
      counts: %{live: 0, remaining: 2},
      progress: %{kind: :exact, percent: 100},
      elapsed: %{label: "1h"},
      eta: %{label: "About 0s remaining"}
    }

    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run,
        usage: %{state: :locked},
        meters: %{state: :locked, cards: []},
        now: @now
      })

    assert html =~ ~s(class="is-critical" style="width:100%")
  end

  # ---- compressed row (more than four panes) ----
  #
  # The GitHub pane counts as a pane, so today's four (GitHub plus three model
  # providers) stay as they are and the fifth provider is what trips the
  # compressed form.

  test "four panes keep the existing provider panes" do
    with_deepseek_key(fn ->
      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: run_view(),
          usage: usage_view(),
          meters: %{state: :authorized, cards: Enum.take(compressed_cards(), 3)},
          github_quota: github_quota_view(),
          now: @now
        })

      refute html =~ "is-compressed"
      refute html =~ "Agent APIs"
      assert html =~ ~s(<section class="run-summary" aria-label="Provider and GitHub usage">)
      # The unchanged panes: a GitHub card plus one card per provider.
      assert pane_count(html) == 4
    end)
  end

  test "a fifth pane collapses the row into one grouped table" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: compressed_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        assert html =~ ~s(<section class="run-summary is-compressed")
        # Exactly one pane, holding every provider.
        assert pane_count(html) == 1

        # The grouping is rendered, not implied by ordering: the agent APIs sit
        # under their own heading and GitHub under "Other".
        assert html =~ "Agent APIs"
        assert html =~ "4 providers"
        assert html =~ "1 provider"

        compacted = compact(html)
        [_, after_agent] = String.split(compacted, "Agent APIs", parts: 2)
        [agent_group, other_group] = String.split(after_agent, "Other", parts: 2)

        for provider <- ["DeepSeek", "Codex", "Claude", "Kimi"], do: assert(agent_group =~ provider)
        refute agent_group =~ "GitHub API"
        assert other_group =~ "GitHub API"
      end)
    end)
  end

  test "the compressed row carries remaining, limit, and reset for each provider" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: compressed_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        assert html =~ "3000/5000 left · resets in 30m"
        assert html =~ "5000/5000 left · resets in 30m"
        # GitHub keeps its own remaining/limit and reset in the compressed row.
        assert html =~ "3750/5000 left · resets in 30m"
      end)
    end)
  end

  # The distinction the compressed row exists to preserve (issue #1564): a
  # stale or unavailable reading must never render like a healthy zero.
  test "the compressed row distinguishes stale and unavailable from a healthy zero" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: compressed_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        compacted = compact(html)

        # DeepSeek is a real, fresh zero-consumed reading.
        assert compacted =~ ~s(DeepSeek</span>)
        assert html =~ ~s(<span class="rs-state is-healthy">Healthy</span>)

        # Claude's window is stale: the reading is labelled rather than
        # presented as current.
        assert html =~ "1900/5000 left · resets in 30m (stale)"
        assert html =~ ~s(<span class="rs-state is-stale">Stale</span>)

        # Kimi reported nothing at all, which is neither healthy nor a zero: it
        # gets the hollow no-measurement track, not an empty bar.
        assert html =~ ~s(<span class="rs-state is-unavailable">Unavailable</span>)
        assert html =~ ~s(<span class="rs-limit-meta">Unavailable</span>)
        assert compacted =~ ~s(<span class="rs-meter rs-meter-none"></span> <span class="rs-limit-meta">Unavailable</span>)

        # DeepSeek's real zero keeps a drawn bar, so the two never read alike.
        assert html =~ ~s(<div class="rs-meter"><i class="" style="width:0%"></i></div>)
      end)
    end)
  end

  test "a secondary-limit backoff renders as a note with no fabricated meter width" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        quota = Map.put(github_quota_view(), :backoffs, [%{resource: "core", seconds_remaining: 45}])

        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: compressed_cards()},
            github_quota: quota,
            now: @now
          })

        assert html =~ "Core backoff"
        assert html =~ "Secondary limit · 45s left"
        assert html =~ ~s(class="rs-meter rs-meter-none")
        assert html =~ ~s(<span class="rs-state is-partial">Backoff</span>)
      end)
    end)
  end

  # Every pane in the strip is an `.rs-block`, whether it is the GitHub card, a
  # vendor card, or the single compressed pane.
  defp pane_count(html), do: length(String.split(html, "rs-block")) - 1

  defp compressed_cards do
    [
      compressed_card(:codex, "Codex", :healthy, "Healthy", [compressed_window("Session", 40, remaining: 3000, limit: 5000)]),
      compressed_card(:claude, "Claude", :stale, "Stale (last known-good)", [
        compressed_window("Session", 62, remaining: 1900, limit: 5000, freshness: :stale)
      ]),
      compressed_card(:deepseek, "DeepSeek", :healthy, "Healthy", [compressed_window("Session", 0, remaining: 5000, limit: 5000)]),
      compressed_card(:kimi, "Kimi", :unavailable, "Unavailable", [])
    ]
  end

  defp compressed_card(provider, label, state, status_label, windows) do
    %{
      provider: provider,
      provider_label: label,
      state: state,
      status_label: status_label,
      auth_mode: %{value: :api_key},
      windows: windows
    }
  end

  defp compressed_window(name, percent, opts) do
    %{
      kind: :rate_limit,
      name: name,
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used: percent,
      used_percent: percent,
      remaining: Keyword.get(opts, :remaining),
      limit: Keyword.get(opts, :limit),
      freshness: Keyword.get(opts, :freshness, :fresh),
      resets_at: DateTime.add(@now, 30, :minute)
    }
  end

  defp github_quota_view do
    %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 3750, limit: 5000, used_percent: 25.0, reset_at: DateTime.add(@now, 30, :minute)}
      },
      attribution: [],
      backoffs: []
    }
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

  defp card(provider) do
    %{
      provider: provider,
      provider_label: provider_label(provider),
      status_label: "Healthy",
      auth_mode: %{value: :api_key},
      windows: []
    }
  end

  defp provider_label(provider) do
    case Aiur.CodingAgent.provider_descriptor(provider) do
      %{label: label} -> label
      _ -> provider |> to_string() |> String.capitalize()
    end
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
  # renderer. `used`/`used_percent` are carried through so the local-concurrency
  # hide-at-zero rule keys on the used value as production does.
  defp scoped_window(limit_id, percent) do
    %{
      limit_id: limit_id,
      kind: :rate_limit,
      name: "Primary",
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used: percent,
      used_percent: percent,
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
