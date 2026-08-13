defmodule AiurWeb.OperatorControlCenter.UsageSummaryTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.{UsageSummary, UsageSummaryPresenter}

  # Concrete protected values and authorized-only regions that must never appear
  # in a denied (locked) render. (The static panel title "Usage and cost" is the
  # feature's accessible name, not a protected value, so it may show when locked.)
  @protected [
    "1000",
    "1500",
    "500",
    "2.50",
    "1.25",
    "USD",
    "$",
    "Pro",
    "gen-1",
    "claude",
    "API-equivalent",
    "Provider-reported",
    "Plan tier",
    "Drill down",
    "Tokens"
  ]

  defp snapshot(overrides \\ %{}) do
    base = %{
      schema_version: 1,
      scope: %{kind: :this_run, run_id: "run-42", tickets: [], rejected_tickets: 0, status: :scoped},
      currency: "USD",
      state: :ok,
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
        by_auth_mode: [contributor(:subscription, "USD", "2.50")],
        by_ticket: [contributor({"acme", "aiur", 42}, "USD", "2.50")],
        by_provider: [],
        by_model: [
          %{key: "claude-sonnet-4", tokens: %{input: 1000, cached_input: 200, output: 500}},
          %{key: "gpt-5.2-codex", tokens: %{input: 300, output: 100}}
        ],
        by_currency: []
      },
      reconciliation: %{reconciled?: true, by_dimension: %{}},
      tier_join_keys: [%{provider: :claude, backend: :app_server, account_generation: "gen-1"}],
      coverage: %{
        selected_cells: 4,
        api_equivalent: %{known: 3, unknown: 1, reasons: [], status: :partial},
        unknown_attribution: %{run_id: 0, ticket: 0, account_generation: 0, resolved_model: 0, pricing_date: 0},
        unknown_pricing_tokens: %{},
        projection: %{folded_records: 10, partial_records: 0, reasons: []},
        source: %{lower: 100, upper: 200, status: :full}
      }
    }

    Map.merge(base, overrides)
  end

  defp contributor(key, currency, amount) do
    %{
      key: key,
      tokens: %{input: 1000},
      provider_reported: %{currency => Decimal.new("1.25")},
      api_equivalent: %{amount: %{currency => Decimal.new(amount)}, coverage: %{known: 3, unknown: 1, reasons: [], status: :partial}}
    }
  end

  defp ready_view(tier_facts \\ %{{:claude, :app_server, "gen-1"} => %{tier: :pro, freshness: :fresh}}) do
    UsageSummaryPresenter.present(snapshot(), tier_facts: tier_facts)
  end

  defp render(view, opts \\ []) do
    render_component(&UsageSummary.usage_summary/1, Keyword.merge([view: view, announcement: "an announcement"], opts))
  end

  test "locked panel renders no protected value" do
    html = render(UsageSummaryPresenter.locked_view())

    assert html =~ "Financial data locked"
    assert html =~ ~s(role="note")
    assert html =~ ~s(role="status")

    for term <- @protected do
      refute String.contains?(html, term), "locked panel leaked protected term #{inspect(term)}"
    end
  end

  test "authorized panel renders a tokens-by-model line chart and destination bars" do
    html = render(ready_view())

    assert html =~ "Tokens by model"
    assert html =~ "<svg"
    assert html =~ "claude-sonnet-4"
    assert html =~ "gpt-5.2-codex"
    # The destination bars name input, output and reasoning.
    assert html =~ ">Input<"
    assert html =~ ">Output<"
    assert html =~ ">Reasoning<"
    # A live-region status remains for screen readers.
    assert html =~ ~s(aria-live="polite")
  end

  test "a model with no additive tokens is omitted from the chart" do
    snap =
      snapshot(%{
        contributors: %{
          snapshot().contributors
          | by_model: [
              %{key: "reasoning-only-model", tokens: %{reasoning_output: 250, provider_reported_total: 900}},
              %{key: "gpt-5.2-codex", tokens: %{input: 300, output: 100}}
            ]
        }
      })

    html = render(UsageSummaryPresenter.present(snap))

    refute html =~ "reasoning-only-model"
    assert html =~ "gpt-5.2-codex"
  end

  test "the long tail of models folds into a single Other line" do
    models =
      for n <- 1..10 do
        %{key: "model-#{n}", tokens: %{input: 100, output: 50}}
      end

    snap = snapshot(%{contributors: %{snapshot().contributors | by_model: models}})
    html = render(UsageSummaryPresenter.present(snap))

    assert html =~ "Other"
  end

  test "stale view shows the last-known-good banner" do
    view = %{ready_view() | state: :stale, freshness: %{status: :stale, label: "Stale"}}
    html = render(view)
    assert html =~ "Stale summary."
  end
end
