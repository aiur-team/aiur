defmodule AiurWeb.OperatorControlCenter.RunSummaryStripTest do
  # The keyed-card filter reads credential env vars, which are process-global,
  # so these tests must not run concurrently with each other.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.{OperatorControlCenter.RunSummaryStrip}

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
  import AiurWeb.OperatorControlCenter.RunSummaryStripFixtures

  test "renders real run, per-provider usage, and rate-limit values" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: run_view(),
        usage: usage_view(),
        meters: meters_view(),
        now: @now
      })

    # Token glyphs and the spend figure were removed (operator directive); the
    # model rows now show only the provider + usage bars.
    assert html =~ ~s(<span class="rs-pc">40%</span>)
    refute html =~ "rs-token-ic"
    refute html =~ "rs-spend"
    refute html =~ "Tokens"
    refute html =~ "Spend"

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

  test "renders the primary GitHub windows and omits separately keyed credentials" do
    github_quota = %{
      state: :observed,
      windows: %{"core" => %{resource: "core", remaining: 4159, limit: 5000, used_percent: 16.8, reset_at: DateTime.add(@now, 30, :minute)}},
      credential_windows: %{"operator-fingerprint" => %{"core" => %{resource: "core", remaining: 4900, limit: 5000, used_percent: 2.0, reset_at: DateTime.add(@now, 30, :minute)}}},
      backoffs: []
    }

    html = render_component(&RunSummaryStrip.run_summary_strip/1, %{run: run_view(), usage: usage_view(), meters: meters_view(), github_quota: github_quota, now: @now})

    assert html =~ "4159/5000 left"
    refute html =~ "4900/5000 left"
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
        configured_providers: MapSet.new([:codex, :claude]),
        now: @now
      })

    # Routed app-server providers render; keyless OpenAI-compatible providers are omitted.
    assert html =~ "Codex"
    assert html =~ "Claude"
    refute html =~ "Kimi"
    refute html =~ "DeepSeek"
    refute html =~ "OpenRouter"
    refute html =~ "$0.00"

    # A locked usage means no real reading: the Limits meter names the
    # unavailable standing, and the removed token glyphs/spend stay absent.
    refute html =~ "N/A"
    refute html =~ "Tokens"
    refute html =~ "rs-token-na"
    refute html =~ "rs-spend"
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

  test "a provider whose spend rounds below a cent still renders, and the total sums exact amounts once" do
    usage = %{
      state: :ready,
      api_equivalent: %{by_currency: [%{currency: "USD", amount: "6.26", amount_exact: "6.258"}]},
      providers: %{
        codex: %{tokens: %{total: 1_500}, api_equivalent: [%{currency: "USD", amount: "<0.01", amount_exact: "0.004"}]},
        claude: %{tokens: %{total: 2_000}, api_equivalent: [%{currency: "USD", amount: "6.25", amount_exact: "6.254"}]}
      }
    }

    html =
      render_component(&RunSummaryStrip.run_summary_compact/1, %{
        run: run_view(),
        usage: usage,
        meters: meters_view(),
        now: @now
      })

    # 0.004 + 6.254 = 6.258 -> 6.26; summing the display strings would raise on
    # "<0.01" or, rounding first, read $6.25.
    assert html =~ "Spend"
    assert html =~ "$6.26"
    refute html =~ "$6.25"
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
end
