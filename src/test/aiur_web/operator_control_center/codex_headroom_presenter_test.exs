defmodule AiurWeb.OperatorControlCenter.CodexHeadroomPresenterTest do
  use ExUnit.Case, async: true

  alias AiurWeb.OperatorControlCenter.CodexHeadroomPresenter

  test "attaches the dispatch headroom value and age only to the Codex card" do
    view = %{state: :authorized, cards: [%{provider: :codex}, %{provider: :claude}]}
    reading = %{windows: %{"short" => 26, "weekly" => 14}, age_seconds: 75, source: "ledger"}

    result = CodexHeadroomPresenter.attach(view, reading)

    assert [%{headroom: %{status: :observed, remaining_percent: 74, age_seconds: 75}}, claude] = result.cards
    refute Map.has_key?(claude, :headroom)
  end

  test "the Units Models view reads Codex headroom from the dispatch ledger the CLI reports" do
    now = ~U[2026-10-18 12:10:00Z]
    ledger = %{"backends" => %{"codex" => %{"observed_at" => "2026-10-18T12:09:30Z", "hourly" => %{"used" => 26, "limit" => 100}}}}

    view = CodexHeadroomPresenter.provider_meters_view(%{state: :authorized}, %{}, state: ledger, now: now, max_reading_age_seconds: 1800)

    assert %{headroom: %{status: :observed, remaining_percent: 74, age_seconds: 30}} = Enum.find(view.cards, &(&1.provider == :codex))
  end

  test "keeps a stale reading unknown and carries its age" do
    view = %{state: :authorized, cards: [%{provider: :codex}]}

    assert %{cards: [%{headroom: headroom}]} =
             CodexHeadroomPresenter.attach(view, %{windows: %{"short" => 2}, age_seconds: 1900, stale: true})

    assert headroom == %{status: :stale, reason: "Last headroom reading is stale", age_seconds: 1900}
  end

  test "an unavailable reading states why and does not invent a value" do
    view = %{state: :authorized, cards: [%{provider: :codex}]}

    assert %{cards: [%{headroom: headroom}]} = CodexHeadroomPresenter.attach(view, nil)
    assert headroom == %{status: :unknown, reason: "No headroom reading is available", age_seconds: nil}
  end
end
