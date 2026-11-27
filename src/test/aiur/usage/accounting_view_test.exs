defmodule Aiur.Usage.AccountingViewTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.AccountingView

  test "returns only the selected user's actual provider usage and ticket breakdown" do
    cells = %{
      {%{provider: :codex, user_id: "user-a", ticket: {:github, "acme", "repo", "11"}, run_id: "run-1"}, {:token, :input}} => 120,
      {%{provider: :codex, user_id: "user-a", ticket: {:github, "acme", "repo", "11"}, run_id: "run-1"}, {:money, :provider_reported_estimate, "USD"}} => Decimal.new("0.25"),
      {%{provider: :claude, user_id: "user-b", ticket: {:github, "acme", "repo", "12"}, run_id: "run-2"}, {:token, :input}} => 900
    }

    reset_at = ~U[2026-11-28 00:00:00Z]

    view =
      AccountingView.build("user-a",
        usage_source: %{cells: cells, metadata: %{health: :healthy, status: "fresh", source_coverage: %{status: "complete"}}},
        meter_views: %{codex: %{windows: %{"weekly" => %{used_percent: 30, resets_at: reset_at}}, freshness: :fresh, observed_at: ~U[2026-11-27 00:00:00Z]}},
        now: ~U[2026-11-27 00:00:00Z]
      )

    assert view.contract == "aiur.usage.accounting"
    assert view.user_id == "user-a"
    assert view.icons.codex.logo == "/provider-assets/codex-color.svg"
    assert view.minerals.status == "actual"
    assert view.minerals.coverage == %{status: "complete"}
    assert view.minerals.providers.codex.tokens == %{"input" => 120}
    assert view.minerals.allocation_periods.codex["weekly"].used_percent == 30
    assert view.minerals.allocation_periods.codex["weekly"].resets_at == "2026-11-28T00:00:00Z"
    assert view.minerals.providers.codex.by_ticket["github:acme/repo#11"].tokens == %{"input" => 120}
    assert Decimal.equal?(view.minerals.providers.codex.money_estimate["provider_reported_estimate:USD"], Decimal.new("0.25"))
    refute Map.has_key?(view.minerals.providers, :claude)
  end

  test "does not report actual zero use when the provider ledger is unavailable" do
    view = AccountingView.build("user-a", usage_source: %{cells: %{}, metadata: %{health: :unavailable}})

    assert view.minerals.status == "unavailable"
    assert view.minerals.providers == %{}
  end
end
