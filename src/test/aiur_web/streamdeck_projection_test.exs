defmodule AiurWeb.StreamdeckProjectionTest do
  use ExUnit.Case, async: true

  alias Aiur.{CodingAgent, ProviderMeterSnapshot}
  alias AiurWeb.OperatorControlCenter.ProviderMetersPresenter
  alias AiurWeb.StreamdeckProjection

  @now ~U[2026-08-09 12:00:00Z]

  test "keeps distinct session and weekly readings for every registry provider" do
    meters = %{
      claude: observed_meter("five_hour", 30, 300, "seven_day", 47, 10_080),
      codex: observed_meter("primary", 50, 60, "secondary", 75, 10_080),
      kimi: observed_meter("session", 10, 120, "weekly", 20, 10_080)
    }

    view = StreamdeckProjection.provider_meters(meters, @now)

    assert Map.keys(view) |> Enum.sort() == CodingAgent.provider_families() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    assert Map.has_key?(view, "claude")
    assert Map.has_key?(view, "codex")
    assert Map.has_key?(view, "kimi")

    assert get_in(view, ["claude", "windows", "session", "used_percent"]) == 30
    assert get_in(view, ["claude", "windows", "weekly", "used_percent"]) == 47
    assert get_in(view, ["codex", "windows", "session", "used_percent"]) == 50
    assert get_in(view, ["codex", "windows", "weekly", "used_percent"]) == 75
    assert get_in(view, ["kimi", "windows", "session", "used_percent"]) == 10
    assert get_in(view, ["kimi", "windows", "weekly", "used_percent"]) == 20
  end

  test "preserves an explicit remaining percentage for the renderer" do
    meter = observed_meter("primary", 40, 60, "secondary", 75, 10_080)
    meter = put_in(meter, [:windows, "primary", :remaining_percent], 65)

    view = StreamdeckProjection.provider_meters(%{codex: meter}, @now)

    assert get_in(view, ["codex", "windows", "session", "used_percent"]) == 40
    assert get_in(view, ["codex", "windows", "session", "remaining_percent"]) == 65
  end

  test "marks retained readings stale from their observation age without trusting freshness" do
    observed_at = DateTime.add(@now, -601, :second)

    view =
      StreamdeckProjection.provider_meters(
        %{codex: observed_meter("primary", 80, 60, "secondary", 90, 10_080, observed_at: observed_at, freshness: :fresh)},
        @now
      )

    assert view["codex"]["age_seconds"] == 601
    assert view["codex"]["freshness"] == "stale"
    assert get_in(view, ["codex", "windows", "session", "freshness"]) == "stale"
    assert get_in(view, ["codex", "windows", "weekly", "freshness"]) == "stale"
  end

  test "propagates a stale provider health state to otherwise fresh windows" do
    meter =
      observed_meter("primary", 80, 60, "secondary", 90, 10_080)
      |> Map.put(:health, %{state: :stale})

    view = StreamdeckProjection.provider_meters(%{codex: meter}, @now)

    assert view["codex"]["freshness"] == "stale"
    assert get_in(view, ["codex", "windows", "session", "freshness"]) == "stale"
    assert get_in(view, ["codex", "windows", "weekly", "freshness"]) == "stale"
  end

  test "keeps a sole weekly source reading in the weekly slot" do
    meter = %{
      state: :observed,
      observed_at: @now,
      freshness: :fresh,
      windows: %{"seven_day" => rate_window(47, 10_080, @now, :fresh)}
    }

    view = StreamdeckProjection.provider_meters(%{claude: meter}, @now)

    refute get_in(view, ["claude", "windows", "session"])
    assert get_in(view, ["claude", "windows", "weekly", "used_percent"]) == 47
  end

  test "retains an observed meter for a configured provider without a dispatchable backend" do
    # The premise is asserted rather than assumed: this criterion is only
    # exercised if the chosen family really is non-dispatchable. If the registry
    # default ever flips, this fails loudly instead of quietly passing against a
    # provider that was dispatchable all along.
    dispatchable = CodingAgent.dispatchable_backends(%{}) |> MapSet.new()
    refute MapSet.member?(dispatchable, "deepseek")
    assert :deepseek in CodingAgent.provider_families()

    view = StreamdeckProjection.provider_meters(%{deepseek: observed_meter("session", 25, 120, "weekly", 45, 10_080)}, @now)

    assert view["deepseek"]["state"] == "observed"
    assert get_in(view, ["deepseek", "windows", "session", "used_percent"]) == 25
    assert get_in(view, ["deepseek", "windows", "weekly", "used_percent"]) == 45
  end

  test "uses the dashboard provider readings without changing their percentages" do
    snapshot = %ProviderMeterSnapshot{
      provider: :codex,
      backend: :app_server,
      provider_account_generation: "gen-codex",
      observed_at: @now,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: @now, last_source_version: 1},
      windows: %{
        "primary" => rate_window(50, 60, @now, :fresh),
        "secondary" => rate_window(75, 10_080, @now, :fresh)
      }
    }

    deck = StreamdeckProjection.provider_meters(%{codex: snapshot}, @now)

    dashboard =
      ProviderMetersPresenter.present(%{state: :authorized}, %{codex: snapshot})
      |> Map.fetch!(:cards)
      |> Enum.find(&(&1.provider == :codex))

    assert get_in(deck, ["codex", "windows", "session", "used_percent"]) == dashboard.windows |> Enum.find(&(&1.limit_id == "primary")) |> Map.fetch!(:used_percent)
    assert get_in(deck, ["codex", "windows", "weekly", "used_percent"]) == dashboard.windows |> Enum.find(&(&1.limit_id == "secondary")) |> Map.fetch!(:used_percent)
  end

  defp observed_meter(session_id, session_percent, session_duration, weekly_id, weekly_percent, weekly_duration, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, @now)
    freshness = Keyword.get(opts, :freshness, :fresh)

    %{
      state: :observed,
      observed_at: observed_at,
      freshness: freshness,
      windows: %{
        session_id => rate_window(session_percent, session_duration, observed_at, freshness),
        weekly_id => rate_window(weekly_percent, weekly_duration, observed_at, freshness)
      }
    }
  end

  defp rate_window(used_percent, duration_minutes, observed_at, freshness) do
    %{
      kind: :rate_limit,
      used_percent: used_percent,
      duration_minutes: duration_minutes,
      observed_at: observed_at,
      freshness: freshness
    }
  end
end
