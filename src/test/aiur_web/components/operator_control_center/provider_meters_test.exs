defmodule AiurWeb.OperatorControlCenter.ProviderMetersTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.ProviderMeters.HostObservations
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

  test "a retained card renders its last-known values with the observation age" do
    snapshot =
      healthy(:codex)
      |> Map.put(:freshness, :stale)
      |> Map.put(:age_seconds, 259_200)
      |> Map.update!(:windows, &Map.update!(&1, "primary", fn window -> Map.put(window, :freshness, :stale) end))
      |> Map.put(:health, %{
        state: :stale,
        failure: :port_closed,
        last_observed_at: @observed,
        last_attempt_at: DateTime.add(@observed, 60, :second),
        consecutive_failures: 3
      })

    view = Presenter.present(authorized(), %{codex: snapshot})
    html = render(view, Presenter.announcement(view))

    assert html =~ ">Stale<"
    assert html =~ "stale observation"
    assert html =~ "Observation age"
    assert html =~ "3 days old"
    refute html =~ "Not live"

    age_only = put_in(snapshot.health.failure, nil)
    announcement = Presenter.present(authorized(), %{codex: age_only}) |> Presenter.announcement()
    assert announcement =~ "Codex: stale observation"
    refute announcement =~ "no earlier values to show"
  end

  test "a failed Muse host refresh labels retained quota stale in the card and announcement" do
    now = ~U[2026-09-27 12:10:00Z]
    observed_at = DateTime.add(now, -10, :second)
    server = start_supervised!({HostObservations, name: nil, clock: fn -> now end})
    {:ok, scope} = HostObservations.attach(server, :muse, :app_server, self())

    assert :ok =
             HostObservations.observe(server, scope, %{
               identity: :unverified,
               host_scope: scope,
               observed_at: observed_at,
               windows: [
                 %{
                   limit_id: "window.current",
                   kind: :rate_limit,
                   name: :primary,
                   source: :provider,
                   observed_at: observed_at,
                   used_percent: 33,
                   resets_at: ~U[2026-09-27 13:00:00Z],
                   coverage: :supported
                 }
               ]
             })

    assert :ok = HostObservations.fail(server, scope, :transport, now)
    snapshot = HostObservations.redacted_snapshot(server, :muse)
    assert snapshot.identity_scope == :host_unverified
    assert snapshot.provider_account_generation == nil
    assert snapshot.age_seconds == 10
    assert snapshot.health.state == :stale
    assert snapshot.health.failure == :transport
    assert snapshot.freshness == :stale
    assert snapshot.windows["window.current"].used_percent == 33
    assert snapshot.windows["window.current"].freshness == :stale

    view = Presenter.present(authorized(), %{muse: snapshot})
    card = Enum.find(view.cards, &(&1.provider == :muse))
    assert card.state == :stale
    assert card.status_label == "Stale"
    assert card.health.label == "Stale"
    assert card.freshness.label == "Stale"
    assert hd(card.windows).freshness_label == "Stale"

    announcement = Presenter.announcement(view)
    assert announcement =~ "Muse: stale observation"
    assert announcement =~ "transport error"

    html = render(view, announcement)
    assert html =~ ~r/provider-meter-badge state-stale[^>]*>Stale<\/span>/
    assert html =~ ~r/<dt>Health<\/dt>\s*<dd>Stale<\/dd>/
    assert html =~ ~s(aria-valuenow="33")
    assert html =~ "10 seconds old"
    refute html =~ "Healthy"
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

    refute html =~ "Account identity unknown"
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
