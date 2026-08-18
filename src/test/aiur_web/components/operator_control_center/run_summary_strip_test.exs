defmodule AiurWeb.OperatorControlCenter.RunSummaryStripTest do
  # The keyed-card filter reads credential env vars, which are process-global,
  # so these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.{OperatorControlCenter.RunSummaryStrip, StaticAssets}

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

  test "renders GitHub core and GraphQL quota with reset" do
    github_quota = %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 3750, limit: 5000, used_percent: 25.0, reset_at: DateTime.add(@now, 30, :minute)},
        "graphql" => %{resource: "graphql", remaining: 500, limit: 5000, used_percent: 90.0, reset_at: DateTime.add(@now, 45, :minute)}
      },
      attribution: [
        %{consumer: "ticket:1670", reads: 8, writes: 2, total: 10, cost: 120, costs: %{"core" => 120}, estimated?: false},
        %{consumer: "unattributed", reads: 1, writes: 0, total: 1, cost: 12, costs: %{"core" => 12}, estimated?: false}
      ],
      coverage: %{
        estimated?: false,
        resources: %{
          "core" => %{attributed: 132, named: 120, spend: 1250, fraction: 0.1056, named_fraction: 0.096, estimated?: false},
          "graphql" => %{attributed: 0, named: 0, spend: 4500, fraction: 0.0, named_fraction: 0.0, estimated?: false}
        }
      }
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: @now
      })

    assert html =~ "Github"
    assert html =~ "APIS"
    assert html =~ "1 API"
    assert html =~ ~s(<img class="rs-logo rs-github-mark" src="/images/github-mark.svg")
    assert html =~ "3750/5000 left · resets in 30m"
    assert html =~ "500/5000 left · resets in 45m"
    assert html =~ ~s(class="is-warning" style="width:90.0%")
    # The two GitHub budgets explain their units on hover.
    assert html =~ ~s(title="REST request budget")
    assert html =~ ~s(title="GraphQL point budget")

    # The top-consumer ranking and per-budget coverage context are removed;
    # no consumer identity leaks through the card.
    refute html =~ "Top consumer"
    refute html =~ "ticket:1670"
    refute html =~ "Attributed"
  end

  # The attribution/coverage context is removed: no ticket identity or
  # attributed-spend lines leak through the card, regardless of window data.
  test "omits attribution and coverage context when only a GraphQL window is observed" do
    github_quota = %{
      state: :observed,
      windows: %{
        "graphql" => %{resource: "graphql", remaining: 0, limit: 5000, used_percent: 100.0, reset_at: DateTime.add(@now, 19, :minute)}
      },
      attribution: [
        %{consumer: "ticket:1790", reads: 2, writes: 0, total: 2, cost: 52, costs: %{"graphql" => 52}, estimated?: false},
        %{consumer: "ticket:1791", reads: 40, writes: 0, total: 40, cost: 40, costs: %{"graphql" => 40}, estimated?: false}
      ],
      coverage: %{
        estimated?: false,
        resources: %{"graphql" => %{attributed: 92, named: 92, spend: 5000, fraction: 0.0184, named_fraction: 0.0184, estimated?: false}}
      }
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: @now
      })

    assert html =~ "0/5000 left"
    refute html =~ "ticket:1790"
    refute html =~ "ticket:1791"
    refute html =~ "Attributed"
  end

  # The attribution/coverage context is removed even when nothing can be
  # attributed to a ticket; the card simply omits it rather than falling silent
  # about a context that no longer exists.
  test "omits attribution and coverage context when nothing can be attributed to a ticket" do
    github_quota = %{
      state: :observed,
      windows: %{
        "graphql" => %{resource: "graphql", remaining: 0, limit: 5000, used_percent: 100.0, reset_at: DateTime.add(@now, 12, :minute)}
      },
      attribution: [%{consumer: "unattributed", reads: 2, writes: 0, total: 2, cost: 2, costs: %{"graphql" => 2}, estimated?: true}],
      coverage: %{
        estimated?: true,
        resources: %{"graphql" => %{attributed: 2, named: 0, spend: 5000, fraction: 0.0004, named_fraction: 0.0, estimated?: true}}
      }
    }

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota,
        now: @now
      })

    refute html =~ "Top consumer"
    refute html =~ "Attributed"
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

  test "partial current facts keep the aggregate percentage without refresh diagnostics" do
    partial_progress = %{
      kind: :partial,
      percent: 40,
      current_member_count: 1,
      total_member_count: 2,
      missing_member_count: 1,
      display_percent_label: "40%",
      current_members_label: "1 of 2 members current"
    }

    settling =
      run_view()
      |> put_in([:progress], Map.merge(partial_progress, %{fact_status: :settling, fact_status_label: "Still settling"}))
      |> put_in([:eta], %{reason: :unhealthy_weight_facts, label: "Unavailable — weight facts unhealthy"})

    degraded =
      settling
      |> put_in([:progress, :fact_status], :degraded)
      |> put_in([:progress, :fact_status_label], "Not updating")

    settling_html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: settling,
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    degraded_html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: degraded,
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    assert settling_html =~ "40%"
    assert settling_html =~ ~s(style="width:40%")
    refute settling_html =~ "Unavailable"
    refute settling_html =~ "weight facts"
    refute settling_html =~ "1 of 2 members current"
    refute settling_html =~ "Still settling"

    assert degraded_html =~ "40%"
    refute degraded_html =~ "Not updating"
    refute degraded_html =~ "Still settling"
  end

  test "unknown aggregate progress keeps a flat inert meter without refresh diagnostics" do
    pending = %{
      kind: :pending,
      percent: nil,
      progress_status_label: "Progress not computed yet",
      current_members_label: "0 of 2 members current",
      fact_status_label: "Still settling"
    }

    run =
      run_view()
      |> put_in([:progress], pending)
      |> put_in([:eta], %{reason: :unhealthy_weight_facts, label: "Unavailable — weight facts unhealthy"})

    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run,
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    assert html =~ ~s(<span class="rs-limit-label">Progress</span>)
    assert html =~ ~s(<span class="rs-limit-meta">—</span>)
    assert html =~ ~s(class="rs-meter is-unknown")
    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-label="Progress unavailable")
    refute html =~ "aria-valuenow"
    refute html =~ ~s(class="rs-meter is-unknown"><i)
    refute html =~ "Progress not computed yet"
    refute html =~ "0 of 2 members current"
    refute html =~ "Still settling"
    refute html =~ "Refresh degraded"
    refute html =~ "weight facts"
    refute html =~ ~s(style="width:40%")
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

  # Codex reports `hasCredits`/`unlimited`/`rateLimitResetCredits` facts, not a
  # prepaid dollar balance. They must not render as a "Credits … balance" row
  # with a meter, which would imply a spendable balance that does not exist.
  test "codex drops its credit windows instead of rendering a balance" do
    meters = %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :ready,
          status_label: "Healthy",
          auth_mode: %{value: :subscription},
          windows: [
            scoped_window("codex:primary", 12),
            %{kind: :credit, name: :credits, coverage_label: "Supported", credits: %{status: :exhausted, label: "Exhausted"}}
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
    refute html =~ "balance"
    refute html =~ "Exhausted"
  end

  # A prepaid balance is a :credit window with no percentage. It must render as
  # a dollar amount, never as a fabricated "0% consumed" bar. Local concurrency
  # is an instantaneous process-local reading, so retaining it on a provider
  # card would turn it into a permanently stale pseudo-limit.
  test "renders a credit balance and omits local concurrency from provider cards" do
    with_deepseek_key(fn ->
      credit = %{
        kind: :credit,
        name: :credits,
        coverage_label: "Supported",
        credits: %{status: :available, label: "Available", amount: 7.25},
        expires_at: DateTime.add(@now, 5, :minute)
      }

      Enum.each([{0, :ready, :fresh}, {5, :stale, :stale}, {42, :ready, :fresh}], fn {used, state, freshness} ->
        concurrency =
          scoped_window("local-concurrency", used)
          |> Map.merge(%{name: "Local concurrency", freshness: freshness, resets_at: nil})

        meters = %{
          state: :authorized,
          cards: [model_card(:deepseek, "DeepSeek", state, "Healthy", [credit, concurrency])]
        }

        html = strip(run: %{state: :loading}, usage: %{state: :ready, providers: %{}}, meters: meters)

        assert html =~ "$7.25"
        refute html =~ "Local concurrency"
        refute html =~ "reset unavailable"
        [_before_provider, provider_html] = String.split(html, "DeepSeek", parts: 2)
        assert length(Regex.scan(~r/<div class="rs-limit">/, provider_html)) == 1
      end)
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
    workflow_path = Path.join(dir, "config.yaml")

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

      # A ledger-only standing is stale by construction, and the meta line is the
      # only place that says so now that the row's head chip is gone.
      assert html =~ "100% used · as of 08:53 UTC (stale)"
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

    # Codex is subscription, so its spend figure is dropped; Claude remains an
    # API-key card and keeps its spend figure (now leading its row).
    refute html =~ "$2.50"
    assert html =~ "$6.25"
  end

  # The provider logo leads the row on the far left and is the row's only mark;
  # the spend figure closes the row on the right.
  test "the provider logo leads the model row and the spend figure closes it" do
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
            windows: []
          }
        ]
      }

      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: %{state: :loading},
          usage: %{state: :locked, providers: %{}},
          meters: meters,
          now: @now
        })

      [before_name, after_name] = String.split(html, "DeepSeek", parts: 2)

      assert before_name =~ ~s(<img class="rs-logo" src=)
      assert after_name =~ "rs-stat-spend"

      # DeepSeek is not Claude or Codex, so it carries no second, right-hand
      # token glyph — one mark per row, on the far left.
      refute after_name =~ ~s(<img class="rs-logo" src=)
      refute after_name =~ "rs-token"
    end)
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
  test "renders each model's own registry logo" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters_view(),
        now: @now
      })

    [_, codex_row, claude_row | _] = String.split(html, ~s(<div class="rs-model">))
    assert codex_row =~ "/provider-assets/codex-color.svg"
    refute codex_row =~ "/provider-assets/claude-symbol.svg"
    assert claude_row =~ "/provider-assets/claude-symbol.svg"
    refute claude_row =~ "/provider-assets/codex-color.svg"
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

  # ---- models pane ----
  #
  # The GitHub card keeps its own pane, and every model provider's progress
  # bars sit together in one 2/3-width pane. The model count does not change
  # the pane count, so there is no overflow to collapse.

  test "GitHub keeps its own pane beside a single models pane" do
    with_deepseek_key(fn ->
      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: run_view(),
          usage: usage_view(),
          meters: %{state: :authorized, cards: Enum.take(model_cards(), 3)},
          github_quota: github_quota_view(),
          now: @now
        })

      assert html =~ ~s(<section class="run-summary" aria-label="Provider and API usage">)
      # Two panes: the GitHub card plus one models pane.
      assert pane_count(html) == 2
      assert html =~ ~s(<div class="rs-block github-quota-card">)
      assert html =~ ~s(<div class="rs-block rs-models" aria-label="Model providers">)
      assert html =~ "3 models"
    end)
  end

  test "a fourth model still fits the single models pane" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: model_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        assert pane_count(html) == 2
        assert html =~ "4 models"

        # Every model is a row inside the one pane, and GitHub is not one of
        # them.
        for provider <- ["DeepSeek", "Codex", "Claude", "Kimi"], do: assert(html =~ provider)
        [_, models_html] = String.split(html, "rs-models", parts: 2)
        refute models_html =~ "Github"
      end)
    end)
  end

  test "each model shows its percentage and reset; GitHub shows remaining and limit" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: model_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        # Model windows render the percent form.
        assert html =~ "40% · resets in 30m"
        assert html =~ "62% · resets in 30m"
        assert html =~ "0% · resets in 30m"
        # GitHub keeps its own remaining/limit and reset in its pane.
        assert html =~ "3750/5000 left · resets in 30m"
      end)
    end)
  end

  # GitHub attribution/coverage context is removed in the full card; no ticket
  # is named a consumer and no attributed-spend line renders.
  test "GitHub card omits attribution and coverage context" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        quota =
          github_quota_view()
          |> Map.put(:attribution, [
            %{consumer: "ticket:1790", reads: 3, writes: 0, total: 3, cost: 78, costs: %{"graphql" => 78}, estimated?: true}
          ])
          |> Map.put(:coverage, %{
            estimated?: true,
            resources: %{
              "core" => %{attributed: 18, named: 18, spend: 1250, fraction: 0.0144, named_fraction: 0.0144, estimated?: false},
              "graphql" => %{attributed: 96, named: 78, spend: 4500, fraction: 0.0213, named_fraction: 0.0173, estimated?: true}
            }
          })

        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: model_cards()},
            github_quota: quota,
            now: @now
          })

        refute html =~ "ticket:1790"
        refute html =~ "Top consumer"
        refute html =~ "Attributed"
      end)
    end)
  end

  # The distinction the models pane exists to preserve (issue #1564): a stale
  # or unavailable reading must never render like a healthy zero.
  test "the models pane distinguishes stale and unavailable from a healthy zero" do
    with_deepseek_key(fn ->
      with_kimi_key(fn ->
        html =
          render_component(&RunSummaryStrip.run_summary_strip/1, %{
            run: run_view(),
            usage: usage_view(),
            meters: %{state: :authorized, cards: model_cards()},
            github_quota: github_quota_view(),
            now: @now
          })

        # DeepSeek is a real, fresh zero-consumed reading.
        assert html =~ "0% · resets in 30m"

        # Claude's window is stale: the reading is labelled rather than
        # presented as current.
        assert html =~ "62% · resets in 30m (stale)"

        # Kimi reported nothing at all, which is neither healthy nor a zero.
        assert html =~ ~s(<span class="rs-limit-meta">Unavailable</span>)

        # The head-row freshness chip is gone (the row leads with the provider
        # logo instead); the meter's own meta line is what keeps the three
        # readings apart, so it is the assertion that guards #1564.
        refute html =~ "rs-state"
      end)
    end)
  end

  # The case the chip used to carry alone: an adapter failure (or repeated probe
  # failures over retained values) leaves the card standing at :stale/:partial
  # while the windows it kept are still stamped fresh. Without a row-level
  # qualifier those percentages read as live ones.
  test "a card standing stale or partial qualifies windows its own freshness calls fresh" do
    for {state, qualifier} <- [{:stale, "(stale)"}, {:partial, "(partial)"}] do
      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: %{state: :loading},
          usage: %{state: :locked, providers: %{}},
          meters: %{
            state: :authorized,
            cards: [
              %{
                provider: :codex,
                provider_label: "Codex",
                state: state,
                status_label: "Retained",
                auth_mode: %{value: :session},
                windows: [Map.put(scoped_window("codex:primary", 40), :freshness, :fresh)]
              }
            ]
          },
          now: @now
        })

      assert html =~ "40% · resets in 30m #{qualifier}"
    end
  end

  # ...and it is added once, not twice, when the window already says it.
  test "a stale window is not qualified twice by a stale card" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :locked, providers: %{}},
        meters: %{
          state: :authorized,
          cards: [
            %{
              provider: :codex,
              provider_label: "Codex",
              state: :stale,
              status_label: "Retained",
              auth_mode: %{value: :session},
              windows: [Map.put(scoped_window("codex:primary", 40), :freshness, :stale)]
            }
          ]
        },
        now: @now
      })

    assert html =~ "40% · resets in 30m (stale)"
    refute html =~ "(stale) (stale)"
  end

  test "a GitHub card still awaiting a response shows the awaiting placeholder" do
    with_deepseek_key(fn ->
      quota = %{github_quota_view() | state: :loading, windows: %{}}

      html =
        render_component(&RunSummaryStrip.run_summary_strip/1, %{
          run: run_view(),
          usage: usage_view(),
          meters: %{state: :authorized, cards: Enum.take(model_cards(), 1)},
          github_quota: quota,
          now: @now
        })

      assert html =~ "Awaiting GitHub response"
    end)
  end

  # ---- ElevenLabs credit quota ----
  #
  # ElevenLabs publishes a character/credit quota plus the amount due on the
  # next invoice. The latter is owed money, never a spendable balance. Like the
  # other meters on this strip, the credit bar fills as usage is consumed.

  test "an unconfigured ElevenLabs account leaves no trace on the strip" do
    html = strip(elevenlabs_quota: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil})

    refute html =~ "ElevenLabs"
    refute html =~ "Credits remaining"
    refute html =~ "rs-elevenlabs"
    assert html =~ "1 API"
    refute html =~ "2 APIs"
  end

  test "an omitted ElevenLabs quota is an absent account, not an empty meter" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        github_quota: github_quota_view(),
        now: @now
      })

    refute html =~ "ElevenLabs"
    assert html =~ "1 API"
  end

  test "a configured account renders a filling used-credit meter and invoice amount beside GitHub" do
    html = strip(elevenlabs_quota: elevenlabs_quota_view())
    row = elevenlabs_row(html)

    assert html =~ "2 APIs"
    assert html =~ "Github"
    assert row =~ "ElevenLabs"
    assert row =~ ~s(src="/elevenlabs-symbol.svg")
    assert row =~ "Credits"
    assert row =~ "75.0K left · 25% used · resets 3d"
    assert row =~ ~s(style="width:25.0%")
    assert row =~ "Next invoice due"
    assert row =~ "$5.00"
    refute row =~ "100.0K"
    refute row =~ "credits left"

    assert {:ok, "image/svg+xml", svg} = StaticAssets.fetch("/elevenlabs-symbol.svg")
    assert svg =~ ~s(<svg width="180" height="292")
  end

  test "the label names the quota it meters and the billing it does not" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view()))

    assert row =~ "account credit quota"
    assert row =~ "Speech-to-text is billed per minute of audio and is not counted here."
    assert row =~ "The dollar figure is the amount due on the next invoice, not a balance."
  end

  test "an absent next invoice does not hide the credit meter" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(next_invoice: nil)))

    assert row =~ "75.0K left · 25% used · resets 3d"
    assert row =~ ~s(style="width:25.0%")
    refute row =~ "Next invoice due"
    refute row =~ "$"
  end

  test "compact reset copy chooses one truthful unit" do
    cases = [
      {DateTime.add(@now, -1, :second), "reset time passed"},
      {DateTime.add(@now, 3, :day), "resets 3d"},
      {DateTime.add(@now, 5, :hour), "resets 5h"},
      {DateTime.add(@now, 45, :minute), "resets 45m"},
      {nil, "reset unavailable"}
    ]

    for {reset_at, expected} <- cases do
      row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(reset_at: reset_at)))
      assert row =~ expected
    end
  end

  test "a configured key with no answer yet says so and draws an empty bar" do
    row = elevenlabs_row(strip(elevenlabs_quota: %{state: :unknown, window: nil, failure: nil, observed_at: nil}))

    assert row =~ "Awaiting ElevenLabs response"
    assert row =~ ~s(class="rs-meter")
    assert row =~ ~s(style="width:0%")
  end

  test "a configured key whose read failed surfaces the failure without the credential" do
    for {failure, sentence} <- [
          {:authentication, "the API key was rejected"},
          {:rate_limited, "rate limited by ElevenLabs"},
          {:provider_error, "ElevenLabs returned an error"},
          {:transport, "ElevenLabs could not be reached"},
          {:malformed, "the response could not be read"}
        ] do
      row = elevenlabs_row(strip(elevenlabs_quota: %{state: :failed, window: nil, failure: failure, observed_at: nil}))

      assert row =~ "Unavailable · " <> sentence
      assert row =~ ~s(class="rs-meter")
      assert row =~ ~s(style="width:0%")
    end
  end

  test "a nearly exhausted quota warns and an exhausted one is critical" do
    warning = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(used: 95_000)))
    assert warning =~ ~s(class="is-warning" style="width:95.0%")

    critical = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(used: 100_000)))
    assert critical =~ ~s(class="is-critical" style="width:100.0%")

    healthy = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view()))
    refute healthy =~ "is-warning"
    refute healthy =~ "is-critical"
  end

  test "a zero character limit renders the credits and an empty bar" do
    row = elevenlabs_row(strip(elevenlabs_quota: elevenlabs_quota_view(limit: 0, used: 0)))

    assert row =~ "0 left"
    assert row =~ ~s(class="rs-meter")
    assert row =~ ~s(style="width:0%")
    refute row =~ "% used"
  end

  # Everything after the ElevenLabs row's marker class and before the next pane.
  defp elevenlabs_row(html) do
    [_before, rest] = String.split(html, "rs-elevenlabs", parts: 2)
    rest |> String.split("rs-block", parts: 2) |> List.first()
  end

  defp strip(opts) do
    defaults = %{run: run_view(), usage: usage_view(), meters: meters_view(), github_quota: github_quota_view(), now: @now}
    render_component(&RunSummaryStrip.run_summary_strip/1, Enum.into(opts, defaults))
  end

  defp elevenlabs_quota_view(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100_000)
    used = Keyword.get(opts, :used, 25_000)

    %{
      state: :observed,
      failure: nil,
      observed_at: @now,
      window: %{
        limit: limit,
        used: used,
        remaining: max(limit - used, 0),
        used_percent: test_used_percent(used, limit),
        next_invoice: Keyword.get(opts, :next_invoice, %{amount_due_cents: 500, currency: "USD"}),
        tier: "creator",
        reset_at: Keyword.get(opts, :reset_at, DateTime.add(@now, 3, :day)),
        observed_at: @now
      }
    }
  end

  defp test_used_percent(_used, limit) when limit <= 0, do: nil

  defp test_used_percent(used, limit) do
    used
    |> Kernel./(limit)
    |> Kernel.*(100)
    |> max(0.0)
    |> min(100.0)
    |> Float.round(1)
  end

  # Every pane in the strip is an `.rs-block`: the GitHub card and the models
  # pane.
  defp pane_count(html), do: length(String.split(html, "rs-block")) - 1

  defp model_cards do
    [
      model_card(:codex, "Codex", :healthy, "Healthy", [model_window("Session", 40, remaining: 3000, limit: 5000)]),
      model_card(:claude, "Claude", :stale, "Not live", [
        model_window("Session", 62, remaining: 1900, limit: 5000, freshness: :stale)
      ]),
      model_card(:deepseek, "DeepSeek", :healthy, "Healthy", [model_window("Session", 0, remaining: 5000, limit: 5000)]),
      model_card(:kimi, "Kimi", :unavailable, "Unavailable", [])
    ]
  end

  defp model_card(provider, label, state, status_label, windows) do
    %{
      provider: provider,
      provider_label: label,
      state: state,
      status_label: status_label,
      auth_mode: %{value: :api_key},
      windows: windows
    }
  end

  defp model_window(name, percent, opts) do
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
  # renderer.
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
