defmodule AiurWeb.OperatorControlCenter.UsageSummaryPresenterTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.UsageSummaryPresenter, as: Presenter

  # A realistic `:ok` grouped snapshot fixture in the DASH-030 shape. Options
  # override the pieces a given test exercises so each case stays focused.
  defp snapshot(overrides \\ %{}) do
    base = %{
      schema_version: 1,
      scope: %{kind: :this_run, run_id: "run-42", tickets: [], rejected_tickets: 0, status: :scoped},
      currency: "USD",
      state: :ok,
      authority: %{aggregate_generation: 7, source_position: 12, source_generation: 3, price_table_revision: "pt-1"},
      health: :healthy,
      freshness: %{status: :fresh},
      retained_interval: %{earliest: 100, latest: 200, status: :full},
      tokens: %{input: 1000, output: 500},
      provider_reported_estimate: %{by_currency: %{"USD" => Decimal.new("1.25")}},
      api_equivalent_estimate: %{
        rollup: %{"USD" => Decimal.new("2.50")},
        coverage: %{known: 3, unknown: 1, reasons: [:unretained_context_tier], status: :partial}
      },
      contributors: %{
        by_provider: [contributor(:claude, "USD", "2.50")],
        by_auth_mode: [contributor(:api_key, "USD", "2.50")],
        by_ticket: [contributor({"acme", "aiur", 42}, "USD", "2.50")],
        by_model: [],
        by_currency: []
      },
      reconciliation: %{reconciled?: true, by_dimension: %{by_provider: true, by_currency: true}},
      tier_join_keys: [%{provider: :claude, backend: :app_server, account_generation: "gen-1"}],
      coverage: %{
        selected_cells: 4,
        api_equivalent: %{known: 3, unknown: 1, reasons: [:unretained_context_tier], status: :partial},
        unknown_attribution: %{run_id: 0, ticket: 0, account_generation: 0, resolved_model: 0, pricing_date: 0},
        unknown_pricing_tokens: %{unretained_context_tier: 42},
        projection: %{folded_records: 10, partial_records: 0, reasons: []},
        source: %{lower: 100, upper: 200, status: :full}
      }
    }

    Map.merge(base, overrides)
  end

  defp contributor(key, currency, amount) do
    %{
      key: key,
      tokens: %{input: 1000, output: 500},
      provider_reported: %{currency => Decimal.new("1.25")},
      api_equivalent: %{amount: %{currency => Decimal.new(amount)}, coverage: %{known: 3, unknown: 1, reasons: [], status: :partial}}
    }
  end

  describe "present/2 core totals" do
    test "names tokens and keeps the two monetary bases separate" do
      view = Presenter.present(snapshot())

      assert view.state == :ready
      assert view.currency == "USD"
      assert Enum.any?(view.tokens.entries, &match?(%{label: "Input", count: 1000}, &1))
      assert view.tokens.total == 1500
      assert view.providers.claude.tokens.total == 1500
      assert [%{currency: "USD", amount: "2.50"}] = view.providers.claude.api_equivalent

      # API-equivalent and provider-reported are distinct, never combined.
      assert [%{currency: "USD", amount: "2.50"}] = view.api_equivalent.by_currency
      assert [%{currency: "USD", amount: "1.25"}] = view.provider_reported.by_currency
      assert view.api_equivalent.estimate? and view.provider_reported.estimate?
    end

    test "unknown cost is named unknown, never zero" do
      snap =
        snapshot(%{
          api_equivalent_estimate: %{rollup: %{}, coverage: %{known: 0, unknown: 5, reasons: [:unretained_context_tier], status: :unknown}}
        })

      view = Presenter.present(snap)

      assert view.api_equivalent.by_currency == []
      assert view.api_equivalent.coverage.status == :unknown
      assert view.api_equivalent.coverage.label =~ "Unknown"
      refute Enum.any?(view.api_equivalent.by_currency, &(&1.amount == "0.00"))
    end

    test "reconciliation flag is surfaced, not recomputed" do
      view = Presenter.present(snapshot(%{reconciliation: %{reconciled?: false, by_dimension: %{by_provider: false}}}))
      refute view.reconciliation.reconciled?
      assert view.reconciliation.by_dimension == %{by_provider: false}
    end
  end

  describe "subscription disclosure" do
    test "a subscription-basis currency is marked and gates the disclosure" do
      snap =
        snapshot(%{
          contributors: %{by_auth_mode: [contributor(:subscription, "USD", "2.50")], by_provider: [], by_ticket: [], by_currency: []}
        })

      view = Presenter.present(snap)

      assert [%{currency: "USD", subscription_marked?: true}] = view.api_equivalent.by_currency
      assert view.disclosure.required?
      assert view.disclosure.marker == "*"
      assert view.disclosure.body =~ "not allocated"
    end

    test "an API-key-only total is not marked and needs no disclosure" do
      view = Presenter.present(snapshot())
      assert [%{subscription_marked?: false}] = view.api_equivalent.by_currency
      refute view.disclosure.required?
    end
  end

  describe "tier join" do
    @tier_facts %{{:claude, :app_server, "gen-1"} => %{tier: :pro, source: :app_server, freshness: :fresh}}

    test "joins an exact known generation and never assigns a combined tier" do
      view = Presenter.present(snapshot(), tier_facts: @tier_facts)

      assert [%{status: :joined, tier: :pro, tier_label: "Pro", generation: "gen-1"}] = view.tier.entries
      assert view.tier.joined_count == 1
      assert view.tier.combined_tier == :none
    end

    test "an unknown or absent generation stays explicitly unjoined" do
      view = Presenter.present(snapshot(), tier_facts: %{})

      assert [%{status: :unjoined, tier: nil}] = view.tier.entries
      assert view.tier.unjoined_count == 1
      assert view.tier.note =~ "unjoined"
    end

    test "a mismatched generation does not borrow another generation's tier" do
      facts = %{{:claude, :app_server, "other-gen"} => %{tier: :enterprise}}
      view = Presenter.present(snapshot(), tier_facts: facts)
      assert [%{status: :unjoined, tier: nil}] = view.tier.entries
    end

    test "mixed generations render per-generation with no combined tier" do
      snap =
        snapshot(%{
          tier_join_keys: [
            %{provider: :claude, backend: :app_server, account_generation: "gen-1"},
            %{provider: :codex, backend: :app_server, account_generation: "gen-2"}
          ]
        })

      view = Presenter.present(snap, tier_facts: @tier_facts)

      assert view.tier.joined_count == 1
      assert view.tier.unjoined_count == 1
      assert view.tier.combined_tier == :none
      assert view.tier.note =~ "per generation"
    end
  end

  describe "coverage" do
    test "source coverage is surfaced separately and named" do
      view = Presenter.present(snapshot())
      assert view.coverage.source_status == :full
      assert view.coverage.source_label == "Full"
      assert view.coverage.unknown_pricing_tokens == %{unretained_context_tier: 42}
    end

    test "unknown contributors are flagged so partial coverage is not zero usage" do
      snap = snapshot(%{coverage: %{snapshot().coverage | unknown_attribution: %{ticket: 3, run_id: 0, account_generation: 0, resolved_model: 0, pricing_date: 0}}})
      view = Presenter.present(snap)
      assert view.coverage.unknown_contributors?
    end

    test "retained interval is preserved with machine-readable bounds" do
      view = Presenter.present(snapshot())
      assert view.retained_interval.earliest == 100
      assert view.retained_interval.latest == 200
      assert view.retained_interval.status == :full
    end
  end

  describe "models" do
    test "ranks models by additive tokens and names each dimension" do
      snap =
        snapshot(%{
          contributors: %{
            snapshot().contributors
            | by_model: [
                %{key: "gpt-5.2-codex", tokens: %{input: 300, output: 100}},
                %{key: "claude-sonnet-4", tokens: %{input: 1000, cached_input: 200, output: 500}}
              ]
          }
        })

      view = Presenter.present(snap)

      assert [
               %{label: "claude-sonnet-4", total: 1700},
               %{label: "gpt-5.2-codex", total: 400}
             ] = view.models.entries

      assert [
               %{dimension: :cached_input, count: 200},
               %{dimension: :input, count: 1000},
               %{dimension: :output, count: 500}
             ] = hd(view.models.entries).segments

      assert view.models.any?
    end

    test "reasoning output and provider totals are never stacked as additive" do
      snap =
        snapshot(%{
          contributors: %{
            snapshot().contributors
            | by_model: [
                %{
                  key: "claude-sonnet-4",
                  tokens: %{input: 1000, output: 500, reasoning_output: 250, provider_reported_total: 1750}
                }
              ]
          }
        })

      view = Presenter.present(snap)
      assert [%{total: 1500} = entry] = view.models.entries
      refute Enum.any?(entry.segments, &(&1.dimension in [:reasoning_output, :provider_reported_total]))
    end

    test "an unknown model key is named unknown" do
      snap =
        snapshot(%{
          contributors: %{
            snapshot().contributors
            | by_model: [%{key: nil, tokens: %{input: 10}}]
          }
        })

      view = Presenter.present(snap)
      assert [%{label: "Unknown", total: 10}] = view.models.entries
    end

    test "an empty by_model contributor set yields no chart entries" do
      view = Presenter.present(snapshot())
      assert view.models.entries == []
      refute view.models.any?
    end
  end

  describe "states" do
    test "each snapshot state maps to a distinct view state" do
      assert Presenter.present(snapshot(%{state: :ok})).state == :ready
      assert Presenter.present(snapshot(%{state: :partial})).state == :partial
      assert Presenter.present(snapshot(%{state: :stale})).state == :stale
      assert Presenter.present(snapshot(%{state: :known_empty})).state == :empty
      assert Presenter.present(snapshot(%{state: :unavailable})).state == :unavailable
      assert Presenter.present(nil).state == :loading
    end

    test "health and freshness variants are each named" do
      degraded = Presenter.present(snapshot(%{health: {:degraded, :source_unavailable}, freshness: %{status: :stale}}))
      assert degraded.health == %{status: :degraded, reason: :source_unavailable, label: "Degraded"}
      assert degraded.freshness.label == "Stale"

      unavailable = Presenter.present(snapshot(%{health: {:unavailable, :compaction_floor_unavailable}}))
      assert unavailable.health.status == :unavailable
    end
  end

  describe "reconcile/2 last-known-good retention" do
    test "adopts an available incoming snapshot" do
      assert {incoming, false} = Presenter.reconcile(snapshot(), snapshot(%{state: :ok}))
      assert incoming.state == :ok
    end

    test "retains a healthy same-scope current across an unavailable update" do
      current = snapshot(%{state: :ok})
      incoming = snapshot(%{state: :unavailable})
      assert {^current, true} = Presenter.reconcile(current, incoming)
    end

    test "shows the incoming snapshot when the scope differs" do
      current = snapshot(%{state: :ok})
      incoming = snapshot(%{state: :unavailable, scope: %{kind: :this_run, run_id: "different", tickets: [], rejected_tickets: 0, status: :scoped}})
      assert {^incoming, false} = Presenter.reconcile(current, incoming)
    end

    test "a retained view reports the failed refresh health but the retained values" do
      source = snapshot(%{state: :ok})
      status_source = snapshot(%{state: :unavailable, health: {:unavailable, :source_unavailable}, freshness: %{status: :unavailable}})

      view = Presenter.present(source, retained?: true, status_source: status_source)

      assert view.state == :stale
      assert view.tokens.total == 1500
      assert view.health.status == :unavailable
      assert view.freshness.label == "Unavailable"
    end
  end

  describe "locked_view/1" do
    test "carries no protected value" do
      view = Presenter.locked_view(%{reason: "Authentication is required to access financial data."})

      assert view.state == :locked
      refute Map.has_key?(view, :tokens)
      refute Map.has_key?(view, :api_equivalent)
      refute Map.has_key?(view, :tier)
      assert view.reason =~ "Authentication is required"
    end
  end

  describe "drill_down/3" do
    test "names contributor entries and separates the monetary bases" do
      page = Presenter.drill_down(snapshot(), :by_ticket, limit: 10)

      assert page.dimension == :by_ticket
      assert page.label == "Ticket"
      assert [entry] = page.items
      assert entry.key_label == "acme/aiur#42"
      assert [%{currency: "USD", amount: "2.50"}] = entry.api_equivalent
      assert [%{currency: "USD", amount: "1.25"}] = entry.provider_reported
    end

    test "marks subscription API-equivalent in drill-down but not provider-reported" do
      snap =
        snapshot(%{
          contributors: %{
            by_auth_mode: [contributor(:subscription, "USD", "2.50")],
            by_provider: [],
            by_ticket: [],
            by_currency: []
          }
        })

      page = Presenter.drill_down(snap, :by_auth_mode, [])
      assert [entry] = page.items
      assert [%{subscription_marked?: true}] = entry.api_equivalent
      assert [%{currency: "USD"}] = entry.provider_reported
    end
  end

  describe "announcement/1" do
    test "ready announcement is bounded and names scope, totals, coverage, health" do
      text = Presenter.present(snapshot(), tier_facts: %{}) |> Presenter.announcement()

      assert text =~ "This run usage."
      assert text =~ "1500 total tokens."
      assert text =~ "API-equivalent estimate 2.50 USD."
      assert text =~ "Provider-reported estimate 1.25 USD."
      assert text =~ "Source coverage Full."
      assert text =~ "Health Healthy, freshness Fresh."
    end

    test "locked and loading announcements leak no value" do
      assert Presenter.announcement(Presenter.locked_view()) =~ "locked"
      assert Presenter.announcement(%{state: :loading}) =~ "Loading"
    end

    test "a subscription total is announced as an estimate" do
      snap = snapshot(%{contributors: %{by_auth_mode: [contributor(:subscription, "USD", "2.50")], by_provider: [], by_ticket: [], by_currency: []}})
      text = snap |> Presenter.present() |> Presenter.announcement()
      assert text =~ "(subscription estimate)"
    end
  end
end
