defmodule AiurWeb.OperatorControlCenter.RunSummaryStripModelsTest do
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
            configured_providers: MapSet.new([:codex, :claude]),
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

    document = Floki.parse_fragment!(html)
    codex_row = document |> Floki.find("[data-provider=codex]") |> Floki.raw_html()
    claude_row = document |> Floki.find("[data-provider=claude]") |> Floki.raw_html()
    assert codex_row =~ "/provider-assets/codex-color.svg"
    refute codex_row =~ "/provider-assets/claude-symbol.svg"
    assert claude_row =~ "/provider-assets/claude-symbol.svg"
    refute claude_row =~ "/provider-assets/codex-color.svg"
  end

  # Rule 6: an unknown token count hides the label and the "N/A", leaving the
  # token glyph alone at logo size in the row's fixed token column.
  test "token glyphs are removed from the model rows" do
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
    refute html =~ "rs-token-na"
    refute html =~ "rs-token-ic"
  end

  # The run progress bar is a separate completion meter; provider quota meters
  # use remaining values and go critical as they approach empty.
  test "a rate-limit bar at 100% used is empty and a 10% remaining bar is critical" do
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

    assert html =~ ~s(<span class="rs-pc is-critical">0% left</span>)
    assert html =~ ~s(aria-valuenow="0")
    refute html =~ ~s(style="width:0%")
  end

  test "a bar at 99% used renders 1% remaining and critical" do
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

    assert html =~ ~s(<span class="rs-pc is-critical">1% left</span>)
    assert html =~ ~s(<i class="is-critical" style="width:1%">)
  end

  test "meter stages follow remaining: warning at 20%, critical at 10%" do
    render = fn percent ->
      meters = %{
        state: :authorized,
        cards: [
          %{
            provider: :codex,
            provider_label: "Codex",
            state: :ready,
            status_label: "Healthy",
            auth_mode: %{value: :api_key},
            windows: [scoped_window("codex:primary", percent)]
          }
        ]
      }

      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        now: @now
      })
    end

    assert render.(0) =~ ~s(<i class="" style="width:100%">)
    assert render.(50) =~ ~s(<i class="" style="width:50%">)
    assert render.(85) =~ ~s(<i class="is-warning" style="width:15%">)
    assert render.(95) =~ ~s(<i class="is-critical" style="width:5%">)
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

        # Model lines read percent, bar, then the reset time beside the recycle
        # icon (#3751); GitHub keeps its own remaining/limit and reset.
        for percent <- ["60% left", "38% left", "100% left"], do: assert(html =~ ~s(<span class="rs-pc">#{percent}</span>))
        assert html =~ "3750/5000 left · 75% left · resets in 30m"
        [_, models_html] = String.split(html, "rs-models", parts: 2)
        # No window label and no filler row: Kimi, with nothing observed, reads unknown.
        refute models_html =~ "rs-limit-label" or models_html =~ "resets in"
        assert models_html =~ ~s(<span class="rs-no">unknown</span>)
        # The SPEND label is deleted from the model rows; the amount keeps its
        # accessible name on the containing stat.
        refute models_html =~ ~s(<span class="rs-stat-label">Spend</span>)
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

  # The models pane shows every provider's reading as a plain percentage; the
  # staleness text qualifier was removed (operator directive), so a stale or
  # unavailable reading carries no label, only the line's stale mark.
  test "the models pane renders stale and unavailable readings without labels" do
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
        assert html =~ ~s(<span class="rs-pc">100% left</span>)

        # Claude's window remains a percentage of quota left. Staleness is
        # conveyed by the line treatment, not a percentage label.
        assert html =~ ~s(<span class="rs-pc">38% left</span>)
        refute html =~ ~r/>[^<]*stale/i

        # Kimi reported nothing at all, which is neither healthy nor a zero; its
        # status label was deleted (operator directive) so the row is just the
        # empty bar.
        refute html =~ ~s(<span class="rs-limit-meta">Unavailable</span>)
        refute html =~ "Unavailable"

        # The head-row freshness chip is gone (the row leads with the provider
        # logo instead); the meter's own meta line is what keeps the three
        # readings apart.
        refute html =~ "rs-state"
      end)
    end)
  end

  # An adapter failure (or repeated probe failures over retained values) leaves
  # the card standing at :stale/:partial while the windows it kept are still
  # stamped fresh. The reading renders as a plain percentage either way.
  test "a card standing stale or partial renders windows without qualifiers" do
    for state <- [:stale, :partial] do
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

      assert html =~ ~s(<span class="rs-pc">60% left</span>)
      refute html =~ "stale"
      refute html =~ "partial"
    end
  end

  test "a stale-stamped window renders its percentage without a text label but with the stale mark" do
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
              windows: [Map.merge(scoped_window("codex:primary", 40), %{freshness: :stale, observed_at: DateTime.add(@now, -13_000, :second)})]
            }
          ]
        },
        now: @now
      })

    assert html =~ ~s(<span class="rs-pc">60% left</span>)
    refute html =~ ~r/>[^<]*stale/i
    assert html =~ ~s(class="rs-ln is-stale")
  end
end
