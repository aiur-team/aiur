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
defmodule Aiur.BrowserHarness.MeterRowLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-18 11:30:00Z]
  @reset ~U[2026-07-18 12:00:00Z]

  @impl true
  def mount(params, _session, socket), do: {:ok, socket |> assign(:now, @now) |> assign(:extra_provider?, Map.get(params, "extra") == "true")}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell" data-meter-row-fixture="true">
      <h1 class="sr-only">Provider meter row fixture</h1>
      <RunSummaryStrip.run_summary_strip
        run={run()}
        usage={usage()}
        meters={meters(@extra_provider?)}
        github_quota={github_quota()}
        elevenlabs_quota={elevenlabs_quota()}
        now={@now}
      />
    </main>
    """
  end

  defp run, do: %{state: :ready, counts: %{remaining: 4}, progress: %{kind: :exact, percent: 60}, elapsed: %{label: "20m"}, eta: %{label: "About 8m remaining"}}

  defp usage do
    %{
      state: :ready,
      providers: %{
        codex: %{tokens: %{total: 1_500}, api_equivalent: [%{currency: "USD", amount: "2.50"}]},
        claude: %{tokens: %{total: 2_000}, api_equivalent: [%{currency: "USD", amount: "6.25"}]}
      }
    }
  end

  # One provider per freshness state the compressed row has to keep
  # distinguishable: a fresh reading, a fresh zero, a stale last-known-good, and
  # a provider that reported nothing at all.
  defp meters(extra_provider?) do
    cards = [
      card(:codex, "Codex", :healthy, "Healthy", [window("Session", 40, 3_000, 5_000, :fresh)]),
      card(:claude, "Claude", :stale, "Stale (last known-good)", [window("Session", 62, 1_900, 5_000, :stale)]),
      card(:deepseek, "DeepSeek", :healthy, "Healthy", [window("Session", 0, 5_000, 5_000, :fresh)]),
      card(:kimi, "Kimi", :unavailable, "Unavailable", [])
    ]

    cards =
      if extra_provider? do
        cards ++ [card(:kimi, "Nova", :healthy, "Healthy", [window("Session", 25, 3_750, 5_000, :fresh)])]
      else
        cards
      end

    %{
      state: :authorized,
      cards: cards
    }
  end

  defp card(provider, label, state, status_label, windows) do
    %{provider: provider, provider_label: label, state: state, status_label: status_label, auth_mode: %{value: :api_key}, windows: windows}
  end

  defp window(name, percent, remaining, limit, freshness) do
    %{
      kind: :rate_limit,
      name: name,
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used: percent,
      used_percent: percent,
      remaining: remaining,
      limit: limit,
      freshness: freshness,
      resets_at: @reset
    }
  end

  defp github_quota do
    %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 3_750, limit: 5_000, used_percent: 25.0, reset_at: @reset},
        "graphql" => %{resource: "graphql", remaining: 500, limit: 5_000, used_percent: 90.0, reset_at: @reset}
      },
      attribution: [
        %{consumer: "ticket:1790", reads: 3, writes: 0, total: 3, cost: 78, costs: %{"graphql" => 78}, estimated?: false},
        %{consumer: "unattributed", reads: 40, writes: 2, total: 42, cost: 96, costs: %{"core" => 96}, estimated?: false}
      ],
      coverage: %{
        estimated?: false,
        resources: %{
          "core" => %{attributed: 96, named: 0, spend: 1_250, fraction: 0.0768, named_fraction: 0.0, estimated?: false},
          "graphql" => %{attributed: 78, named: 78, spend: 4_500, fraction: 0.0173, named_fraction: 0.0173, estimated?: false}
        }
      },
      backoffs: [%{resource: "core", until: DateTime.add(@now, 45, :second), seconds_remaining: 45}]
    }
  end

  defp elevenlabs_quota do
    %{
      state: :observed,
      failure: nil,
      observed_at: @now,
      window: %{
        limit: 100_000,
        used: 25_000,
        remaining: 75_000,
        used_percent: 25.0,
        next_invoice: %{amount_due_cents: 500, currency: "USD"},
        tier: "creator",
        reset_at: DateTime.add(@now, 3, :day),
        observed_at: @now
      }
    }
  end
end

# The GitHub quota card as an operator sees it when both budgets are gone: the
# state the panel was reported wrong in (#1805). Two providers keep the strip
# out of its compressed form, so this is the full card, not the grouped table.
defmodule Aiur.BrowserHarness.QuotaPanelLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-18 11:30:00Z]
  @core_reset ~U[2026-07-18 11:42:00Z]
  @graphql_reset ~U[2026-07-18 11:49:00Z]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :now, @now)}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell" data-quota-panel-fixture="true">
      <h1 class="sr-only">GitHub quota panel fixture</h1>
      <RunSummaryStrip.run_summary_strip run={run()} usage={usage()} meters={meters()} github_quota={github_quota()} now={@now} />
    </main>
    """
  end

  defp run, do: %{state: :ready, counts: %{remaining: 4}, progress: %{kind: :exact, percent: 60}, elapsed: %{label: "20m"}, eta: %{label: "About 8m remaining"}}

  defp usage do
    %{state: :ready, providers: %{codex: %{tokens: %{total: 1_500}, api_equivalent: [%{currency: "USD", amount: "2.50"}]}}}
  end

  defp meters do
    %{
      state: :authorized,
      cards: [
        %{
          provider: :codex,
          provider_label: "Codex",
          state: :healthy,
          status_label: "Healthy",
          auth_mode: %{value: :api_key},
          windows: [
            %{
              kind: :rate_limit,
              name: "Session",
              coverage_label: "Supported",
              meter: %{kind: :exact, now: 40, min: 0, max: 100},
              used: 40,
              used_percent: 40,
              remaining: 3_000,
              limit: 5_000,
              freshness: :fresh,
              resets_at: @graphql_reset
            }
          ]
        }
      ]
    }
  end

  # The reported numbers: both budgets exhausted, a heavy GraphQL consumer
  # measured in points, and a coverage figure stated per budget — core's
  # requests against core's window, GraphQL's points against GraphQL's, which
  # reset seven minutes apart and therefore share no denominator.
  #
  # Only the GraphQL rows carry `estimated?`, because that is the only place the
  # quota module can produce it: core calls are always billed one request and
  # recorded `:reported`.
  defp github_quota do
    %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 0, limit: 5_000, used_percent: 100.0, reset_at: @core_reset},
        "graphql" => %{resource: "graphql", remaining: 0, limit: 5_000, used_percent: 100.0, reset_at: @graphql_reset}
      },
      attribution: [
        %{consumer: "ticket:1790", reads: 12, writes: 1, total: 13, cost: 338, costs: %{"graphql" => 312, "core" => 26}, estimated?: false},
        %{consumer: "ticket:1792", reads: 44, writes: 3, total: 47, cost: 47, costs: %{"core" => 47}, estimated?: false},
        %{consumer: "unattributed", reads: 21, writes: 0, total: 21, cost: 21, costs: %{"graphql" => 21}, estimated?: true}
      ],
      coverage: %{
        estimated?: true,
        resources: %{
          "core" => %{attributed: 73, named: 73, spend: 5_000, fraction: 0.0146, named_fraction: 0.0146, estimated?: false},
          "graphql" => %{attributed: 333, named: 312, spend: 5_000, fraction: 0.0666, named_fraction: 0.0624, estimated?: true}
        }
      },
      backoffs: []
    }
  end
end
