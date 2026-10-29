defmodule AiurWeb.OperatorControlCenter.ModelProvidersTest do
  # The keyed rule reads credential env vars, which are process-global.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AiurWeb.OperatorControlCenter.ModelProviders
  alias AiurWeb.OperatorControlCenter.RunSummaryStrip

  @none MapSet.new()

  setup do
    previous = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if previous, do: System.put_env("DEEPSEEK_API_KEY", previous), else: System.delete_env("DEEPSEEK_API_KEY")
    end)
  end

  defp card(provider, extra \\ %{}), do: Map.merge(%{provider: provider, provider_label: to_string(provider), windows: []}, extra)

  test "a session provider with no configured account and no observation is a placeholder" do
    refute ModelProviders.visible?(card(:muse), @none)
    assert ModelProviders.visible(Enum.map([:muse, :claude], &card/1), MapSet.new([:claude])) == [card(:claude)]
  end

  test "a configured session provider stays visible while its data is unknown" do
    assert ModelProviders.visible?(card(:codex), MapSet.new([:codex]))
    assert ModelProviders.visible?(card(:muse), MapSet.new([:muse]))
  end

  test "a real observation keeps an unconfigured session provider visible" do
    assert ModelProviders.visible?(card(:muse, %{windows: [%{kind: :rate_limit}]}), @none)
    assert ModelProviders.visible?(card(:claude, %{account_usage: %{accounts: [%{name: "default"}]}}), @none)
    assert ModelProviders.visible?(card(:codex, %{durable_observation: %{percent: 40}}), @none)
    refute ModelProviders.visible?(card(:claude, %{account_usage: %{accounts: []}}), @none)
  end

  test "an OpenAI-compatible provider is shown only when its credential is set" do
    refute ModelProviders.visible?(card(:deepseek, %{windows: [%{kind: :credit}]}), MapSet.new([:deepseek]))

    System.put_env("DEEPSEEK_API_KEY", "test-key")
    assert ModelProviders.visible?(card(:deepseek), @none)

    System.put_env("DEEPSEEK_API_KEY", "")
    refute ModelProviders.visible?(card(:deepseek), @none)
  end

  test "the strip drops the Muse placeholder but keeps a routed provider whose data is unknown" do
    meters = %{state: :authorized, cards: [card(:muse, %{state: :loading}), card(:claude, %{state: :loading})]}

    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: meters,
        github_quota: %{
          fleet_budget: %{
            state: :observed,
            observed_at: ~U[2026-10-24 12:00:00Z],
            age_seconds: 8,
            observed_instances: 2,
            resources: %{"core" => 31, "graphql" => 60, "search" => 2}
          }
        },
        configured_providers: MapSet.new([:claude]),
        now: ~U[2026-07-20 12:00:00Z]
      })

    assert html =~ ~s(data-provider="claude")
    assert html =~ ~s(<span class="rs-no">unknown</span>)
    assert html =~ "1 model"
    assert html =~ "Shared daemon spend: Core 31 requests, GraphQL 60 points across 2 observed instances (8s old)"
    assert html =~ "agent gh calls are counted per host"
    refute html =~ "Muse"
    refute html =~ "Not observed"
  end

  test "the dashboard labels an unavailable fleet sample instead of showing zero spend" do
    html =
      render_component(&RunSummaryStrip.run_summary_strip/1, %{
        run: %{state: :loading},
        usage: %{state: :ready, providers: %{}},
        meters: %{state: :authorized, cards: []},
        github_quota: %{fleet_budget: %{state: :unknown}},
        configured_providers: [],
        now: ~U[2026-10-24 12:00:00Z]
      })

    assert html =~ "Shared daemon budget has no fleet sample yet"
    assert html =~ "agent gh calls are counted per host"
    refute html =~ "Core 0 requests"
  end

  test "configured families follow the workflow's routed backends, not the registry" do
    families = ModelProviders.configured_families()

    assert Enum.member?(families, String.to_atom(Aiur.CodingAgent.backends()[Aiur.Config.agent_kind()].family))
    refute :muse in families
  end
end
