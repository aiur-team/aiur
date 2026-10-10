defmodule Aiur.BrowserHarness.ModelsPanelLive do
  @moduledoc false
  # The operator's live MODELS panel (#3751): DeepSeek prepaid credits, Claude
  # with two named accounts plus its session and weekly windows, Codex with an
  # account-wide and a per-model primary window, and a Muse card with no
  # configured account and no observation (a placeholder that must not render).
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @now ~U[2026-07-18 11:30:00Z]

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :now, @now)}

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell" data-models-panel-fixture="true">
      <h1 class="sr-only">Models panel fixture</h1>
      <RunSummaryStrip.run_summary_strip
        run={%{state: :loading}}
        usage={%{state: :ready, providers: %{}}}
        meters={meters()}
        github_quota={github_quota()}
        configured_providers={MapSet.new([:claude, :codex])}
        now={@now}
      />
    </main>
    """
  end

  defp meters do
    %{state: :authorized, cards: [deepseek(), claude(), codex(), muse()]}
  end

  defp deepseek do
    credits = %{kind: :credit, name: "Credits", limit_id: "deepseek:balance", used_percent: 2.3, credits: %{amount: 10.4, status: :available}}
    card(:deepseek, "DeepSeek", [credits], %{health: %{age_label: "15 seconds old"}})
  end

  defp claude do
    windows = [
      window("claude:five_hour", "Session (5 hour)", 9.5, nil, after_now(4 * 3_600 + 2 * 60)),
      window("claude:seven_day", "Weekly (all models)", 12.0, nil, after_now(6 * 86_400 + 15 * 3_600 + 52 * 60))
    ]

    accounts = [
      %{name: "default", index: 0, percent: 0.0, freshness: :fresh, age_seconds: 15, resets_at: after_now(2 * 86_400 + 3 * 3_600)},
      %{name: "everdred", index: 1, percent: 12.0, freshness: :fresh, age_seconds: 15, resets_at: after_now(6 * 86_400 + 15 * 3_600 + 52 * 60)}
    ]

    card(:claude, "Claude", windows, %{
      health: %{age_label: "15 seconds old"},
      summary_label: "worst of 2 accounts · everdred",
      account_usage: %{count: 2, total_percent: 12.0, accounts: accounts}
    })
  end

  defp codex do
    windows = [
      window("codex:primary", "Primary", 62, 10_080, after_now(5 * 86_400 + 4 * 3_600 + 59 * 60)),
      window("codex_bengalfox:primary", "Primary", 3, 300, after_now(30 * 60))
    ]

    card(:codex, "Codex", windows, %{health: %{age_label: "0 seconds old"}})
  end

  defp muse, do: card(:muse, "Muse", [], %{state: :loading})

  defp card(provider, label, windows, extra) do
    Map.merge(%{provider: provider, provider_label: label, state: :healthy, status_label: "Healthy", auth_mode: %{value: :subscription}, windows: windows}, extra)
  end

  defp window(limit_id, name, percent, duration_minutes, resets_at) do
    %{
      kind: :rate_limit,
      limit_id: limit_id,
      name: name,
      coverage_label: "Supported",
      meter: %{kind: :exact, now: percent, min: 0, max: 100},
      used_percent: percent,
      duration_minutes: duration_minutes,
      freshness: :fresh,
      resets_at: resets_at
    }
  end

  defp after_now(seconds), do: DateTime.add(@now, seconds, :second)

  defp github_quota do
    reset = after_now(30 * 60)

    %{
      state: :observed,
      windows: %{
        "core" => %{resource: "core", remaining: 4_736, limit: 5_000, used_percent: 5.3, reset_at: reset},
        "graphql" => %{resource: "graphql", remaining: 4_998, limit: 5_000, used_percent: 0.0, reset_at: reset}
      },
      attribution: [],
      coverage: nil,
      backoffs: []
    }
  end
end
