defmodule Aiur.BrowserHarness.ProviderMetersLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.ProviderMeterSnapshot
  alias AiurWeb.OperatorControlCenter.{ProviderMeters, ProviderMetersPresenter}

  @observed ~U[2026-07-18 11:30:00Z]
  @reset ~U[2026-07-18 12:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :capability, %{state: :authorized, version: 1})}
  end

  @impl true
  def handle_event("lock", _params, socket) do
    {:noreply, assign(socket, :capability, AiurWeb.FinancialDataAccess.locked_capability())}
  end

  def handle_event("unlock", _params, socket) do
    {:noreply, assign(socket, :capability, %{state: :authorized, version: 1})}
  end

  @impl true
  def render(assigns) do
    view = ProviderMetersPresenter.present(assigns.capability, snapshots())

    assigns =
      assigns
      |> assign(:view, view)
      |> assign(:announcement, ProviderMetersPresenter.announcement(view))

    ~H"""
    <main class="app-shell" data-provider-meters-fixture="true">
      <h1 class="sr-only">Provider meters fixture</h1>
      <ProviderMeters.provider_meters view={@view} announcement={@announcement} />

      <div class="controls" aria-label="Provider meter fixture updates">
        <button id="lock-provider-meters" type="button" phx-click="lock">Lock provider meters</button>
        <button id="unlock-provider-meters" type="button" phx-click="unlock">Unlock provider meters</button>
      </div>
    </main>
    """
  end

  defp snapshots do
    %{codex: codex(), claude: ProviderMeterSnapshot.unknown(:claude, :app_server)}
  end

  defp codex do
    %ProviderMeterSnapshot{
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "fixture-codex-generation",
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
        },
        "credits" => %{kind: :credit, name: "Credits", coverage: :unsupported, standing: nil, used_percent: nil, source: :codex_app_server}
      }
    }
  end
end

# The provider meter row above Units carries today's four model providers and
# can add one hypothetical provider through `?extra=true`. Browser coverage uses
# both shapes to prove another provider adds one fixed-height row without
# changing the existing rows' columns or measurements.
