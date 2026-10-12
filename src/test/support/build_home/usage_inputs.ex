defmodule Aiur.TestSupport.BuildHome.UsageInputs do
  @moduledoc false
  alias Aiur.ProviderMeterSnapshot
  @now ~U[2026-10-08 12:00:00Z]
  def now, do: @now

  def inputs(overrides \\ %{}) do
    Map.merge(%{families: [:codex], meters: %{}, accounts: %{}, durable: %{}, github: {:ok, %{state: :unknown, windows: %{}, backoffs: []}}, elevenlabs: %{state: :unconfigured}}, overrides)
  end

  def snapshot(provider, windows, overrides \\ %{}) do
    struct(
      ProviderMeterSnapshot,
      Map.merge(%{provider: provider, provider_account_generation: "private-generation", observed_at: @now, health: %{state: :healthy, failure: nil}, windows: windows}, overrides)
    )
  end

  def window(percent, minutes \\ nil, overrides \\ %{}) do
    Map.merge(%{kind: :rate_limit, coverage: :supported, used_percent: percent, duration_minutes: minutes, resets_at: DateTime.add(@now, 3600)}, overrides)
  end

  def account(session, weekly) do
    %{
      observed_at: @now,
      freshness: :fresh,
      reading: %{windows: [%{window: "five_hour", used_percent: session, resets_at: DateTime.add(@now, 3600)}, %{window: "seven_day", used_percent: weekly, resets_at: DateTime.add(@now, 7200)}]}
    }
  end

  def quota(core \\ 4736, graphql \\ 4998) do
    windows =
      Map.new([{"core", core}, {"graphql", graphql}], fn {key, remaining} ->
        {key, %{limit: 5000, remaining: remaining, used_percent: (5000 - remaining) / 50, reset_at: DateTime.add(@now, 3600), observed_at: @now}}
      end)

    %{state: :observed, windows: windows, backoffs: []}
  end

  def psets4 do
    meters =
      Map.new([{:claude, 1, 96}, {:codex, 0, 0}, {:kimi, 9, 14}], fn {provider, session, weekly} ->
        {provider, snapshot(provider, %{"primary" => window(session, 300), "secondary" => window(weekly, 10_080)})}
      end)

    credit = window(2.0, nil, %{kind: :credit, credits: %{status: :available, amount: 10.4}, remaining: 10.4})

    inputs(%{
      families: [:codex, :claude, :deepseek, :kimi],
      meters: Map.put(meters, :deepseek, snapshot(:deepseek, %{"balance" => credit})),
      accounts: %{"Max · work" => account(1, 96), "Pro · personal" => account(3, 86)},
      github: {:ok, quota()}
    })
  end
end
