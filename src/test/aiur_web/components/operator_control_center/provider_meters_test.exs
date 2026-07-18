defmodule AiurWeb.OperatorControlCenter.ProviderMetersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.OperatorControlCenter.ProviderMeters
  alias AiurWeb.OperatorControlCenter.ProviderMetersPresenter, as: Presenter

  @reset ~U[2026-07-18 12:00:00Z]
  @observed ~U[2026-07-18 11:30:00Z]

  test "locked view renders the content-free locked banner and no protected facts" do
    view =
      Presenter.present(
        %{
          state: :locked,
          accessible_name: "Provider meters locked",
          reason: "Authentication is required to access provider meters.",
          authentication_path: "Sign in with the configured dashboard credentials."
        },
        %{codex: healthy(:codex)}
      )

    html = render(view, Presenter.announcement(view))

    assert html =~ "Provider meters locked"
    assert html =~ ~s(role="status")
    refute html =~ "provider-meter-card"
    refute html =~ "aria-valuenow"
    refute html =~ "gen-codex"
    refute html =~ "<dt>Plan</dt>"
    refute html =~ "role=\"progressbar\""
  end

  test "healthy card exposes semantic progressbar, machine-readable reset time, and provenance" do
    view = Presenter.present(authorized(), %{codex: healthy(:codex)})
    html = render(view, Presenter.announcement(view))

    assert html =~ ~s(id="provider-meter-codex-title")
    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-valuenow="40")
    assert html =~ ~s(aria-valuemin="0")
    assert html =~ ~s(aria-valuemax="100")
    assert html =~ ~s(<time)
    assert html =~ ~s(datetime="2026-07-18T12:00:00Z")
    assert html =~ "Subscription"
    assert html =~ "<dt>Plan</dt>"
    assert html =~ "<dd>Pro</dd>"
  end

  test "the live-region announcement is polite and atomic" do
    view = Presenter.present(authorized(), %{codex: healthy(:codex)})
    html = render(view, Presenter.announcement(view))

    assert html =~ ~s(aria-live="polite")
    assert html =~ ~s(aria-atomic="true")
  end

  test "an unknown identity renders no progressbar value and no borrowed plan" do
    snapshot = ProviderMeterSnapshot.unknown(:codex, :app_server)
    view = Presenter.present(authorized(), %{codex: snapshot})
    html = render(view, Presenter.announcement(view))

    assert html =~ "Account identity unknown"
    refute html =~ ~s(aria-valuenow)
    refute html =~ "<dt>Plan</dt>"
  end

  test "an unsupported window names its coverage without a meter value" do
    window = %{kind: :rate_limit, name: "Primary", coverage: :unsupported, standing: nil, used_percent: nil, source: :codex_app_server}
    snapshot = %{healthy(:codex) | windows: %{"primary" => window}}
    view = Presenter.present(authorized(), %{codex: snapshot})
    html = render(view, Presenter.announcement(view))

    assert html =~ "Not supported"
    refute html =~ ~s(aria-valuenow)
  end

  test "a not-yet-loaded provider renders the loading state" do
    view = Presenter.present(authorized(), %{codex: nil, claude: nil})
    html = render(view, Presenter.announcement(view))
    assert html =~ "Loading account meters"
  end

  defp render(view, announcement) do
    render_component(&ProviderMeters.provider_meters/1, view: view, announcement: announcement)
  end

  defp authorized, do: %{state: :authorized, version: 1}

  defp healthy(provider) do
    %ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-#{provider}",
      auth_mode: :subscription,
      plan: %{tier: :pro, source: :provider, observed_at: @observed, freshness: :fresh},
      observed_at: @observed,
      ingested_at: @observed,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: @observed, last_source_version: 1},
      windows: %{
        "primary" => %{
          kind: :rate_limit,
          name: "Primary",
          standing: :allowed,
          used_percent: 40,
          remaining_percent: 60,
          coverage: :supported,
          freshness: :fresh,
          resets_at: @reset,
          source: :codex_app_server
        }
      }
    }
  end
end
