defmodule AiurWeb.OperatorControlCenter.RunSummaryStripCreditTest do
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

      assert html =~ ~s(<span class="rs-pc">2%</span>) and html =~ ~s(<b class="rs-usd">$49.05</b>)
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

      assert html =~ ~s(<b class="rs-usd">$0.00</b>)
      assert html =~ ~s(class="is-critical" style="width:100.0%")
    end)
  end

  # A credit window whose freshness horizon has passed is no longer a current
  # reading (issue #1550); the dashboard no longer labels it, so the meta just
  # keeps the balance.
  test "a credit window past its freshness horizon keeps its balance without a stale label" do
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

      assert html =~ "$7.25"
      refute html =~ "stale"
    end)
  end

  # A balance observed more than four minutes ago (within the final minute of
  # its 300s freshness horizon, or past it) still shows its measured spend; the
  # staleness qualifier was removed (operator directive).
  test "a credit balance observed more than four minutes ago keeps its measured spend" do
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

      assert html =~ ~s(<span class="rs-pc">2%</span>) and html =~ ~s(<b class="rs-usd">$49.05</b>)
      refute html =~ "stale"
    end)
  end

  # A provider that has never been observed this boot reads :unknown — a bare
  # N/A — even when the durable dispatch-limits ledger holds its last standing.
  # The strip must degrade to that durable record instead of rendering an empty
  # card. A fully-consumed durable record also turns the bar red.
  test "renders the durable last-known standing with a red-at-100 bar" do
    observed_at = ~U[2026-08-02 08:53:00Z]
    dir = Aiur.TestSupport.tmp_root!("aiur-strip-durable")
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

      assert html =~ "100%"
      refute html =~ "stale"
      assert html =~ ~s(class="is-critical" style="width:100%")
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
  end

  test "omits the status label for a provider with no durable record either" do
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

      refute html =~ "N/A"
      refute html =~ "—"
    end)
  end

  test "spend figures are removed for every account" do
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

    # The spend figure was removed entirely (operator directive): no amount on
    # any model row, subscription or API-key.
    refute html =~ "$2.50"
    refute html =~ "$6.25"
    refute html =~ "rs-spend"
  end

  # The provider logo leads the row on the far left and is the row's only mark;
  # the spend figure and token glyphs were removed (operator directive).
  test "the provider logo leads the model row, with no spend or token glyph" do
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

      [before_name, after_name] = String.split(html, ~s(<span class="rs-name">DeepSeek), parts: 2)

      assert before_name =~ ~s(<img class="rs-logo" src=)
      refute after_name =~ "rs-spend"
      refute after_name =~ "rs-token"
      refute after_name =~ ~s(<img class="rs-logo" src=)
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
end
