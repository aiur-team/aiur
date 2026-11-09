defmodule AiurWeb.OperatorControlCenter.HostMeterTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.OperatorControlCenter.{ProviderMeters, ProviderMetersPresenter}

  test "host allowance renders unverified scope and measured age without an account claim" do
    snapshot = %ProviderMeterSnapshot{
      provider: :muse,
      backend: :app_server,
      identity_scope: :host_unverified,
      age_seconds: 17,
      observed_at: ~U[2026-09-27 12:00:00Z],
      freshness: :fresh,
      health: %{state: :healthy},
      windows: %{"muse.current" => %{name: "Current", kind: :rate_limit, used_percent: 123.5, coverage: :supported}}
    }

    view = ProviderMetersPresenter.present(%{state: :authorized}, %{muse: snapshot})
    card = Enum.find(view.cards, &(&1.provider == :muse))
    assert card.identity == %{state: :unverified, generation: nil, generation_label: nil}
    assert card.health.age_seconds == 17
    assert [%{used_percent: 123.5}] = card.windows
    html = render_component(&ProviderMeters.provider_meters/1, view: view)
    assert html =~ "Current host · account unverified"
    assert html =~ "17 seconds old"
    refute html =~ "Account generation"
  end

  test "unobserved host does not acquire a zero allowance or invented age" do
    snapshot = %{ProviderMeterSnapshot.unknown(:muse, :app_server) | identity_scope: :host_unverified}
    view = ProviderMetersPresenter.present(%{state: :authorized}, %{muse: snapshot})
    card = Enum.find(view.cards, &(&1.provider == :muse))
    assert card.windows == []
    assert card.health.age_seconds == nil
    assert card.health.age_label == nil
    html = render_component(&ProviderMeters.provider_meters/1, view: view)
    # Keep the existing live-card guards after the strip renderer retires.
    refute html =~ "0 seconds old"
    assert html =~ "Current host · account unverified"
  end
end
