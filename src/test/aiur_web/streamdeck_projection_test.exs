defmodule AiurWeb.StreamdeckProjectionTest do
  # The durable-fallback test writes a fixture `model-usage.json` beside a
  # throwaway workflow file, which mutates the suite-global workflow path, so
  # this file must not run concurrently with other tests that read it.
  use ExUnit.Case, async: false

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

  test "maps native codex account windows while ignoring its non-balance credit facts" do
    meter = %{
      state: :observed,
      observed_at: @now,
      freshness: :fresh,
      windows: %{
        "codex:primary" => rate_window(2, 300, @now, :fresh),
        "codex:secondary" => rate_window(18, 10_080, @now, :fresh),
        "codex:credits" => credit_window(44, @now)
      }
    }

    view = StreamdeckProjection.provider_meters(%{codex: meter}, @now)

    assert get_in(view, ["codex", "windows", "session", "used_percent"]) == 2
    assert get_in(view, ["codex", "windows", "weekly", "used_percent"]) == 18
  end

  test "projects a prepaid provider credit window into the governing session slot" do
    meter = %{
      state: :observed,
      observed_at: @now,
      freshness: :fresh,
      windows: %{"deepseek:credits" => credit_window(44, @now)}
    }

    view = StreamdeckProjection.provider_meters(%{deepseek: meter}, @now)

    assert get_in(view, ["deepseek", "windows", "session", "used_percent"]) == 44
    assert get_in(view, ["deepseek", "windows", "session", "remaining"]) == 10.93
    refute get_in(view, ["deepseek", "windows", "weekly"])
  end

  # The dashboard's provider cards attach a provider's durable last-known
  # standing from the dispatch-limits ledger when the live meter has no
  # observation (`put_durable_observation` in RunSummaryStrip). The deck must
  # read the same record, or a provider the dashboard shows at 99% used renders
  # as a permanent "Awaiting data" on the strip — two surfaces disagreeing about
  # the same account (#2185).
  test "attaches the durable last-known standing to an unobserved provider's session meter" do
    dir = Path.join(System.tmp_dir!(), "aiur-sd-durable-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    workflow_path = Path.join(dir, "config.yaml")
    observed_at = ~U[2026-08-02 08:53:00Z]
    previous_path = Application.get_env(:aiur, :workflow_file_path)

    try do
      Application.put_env(:aiur, :workflow_file_path, workflow_path)

      :ok =
        Aiur.ModelAvailability.observe(
          "deepseek",
          %{weekly: %{used: 99, limit: 100, reset_at: DateTime.add(@now, 86_400, :second) |> DateTime.to_iso8601()}},
          now: observed_at
        )

      view =
        StreamdeckProjection.provider_meters(
          %{deepseek: %{state: :unknown, observed_at: nil, freshness: :unknown, windows: %{}}},
          @now
        )

      deepseek = view["deepseek"]
      assert deepseek["state"] == "observed"
      assert deepseek["freshness"] == "stale"
      assert deepseek["observed_at"] == DateTime.to_iso8601(observed_at)
      assert deepseek["age_seconds"] == DateTime.diff(@now, observed_at)
      assert get_in(deepseek, ["windows", "session", "used_percent"]) == 99
      assert get_in(deepseek, ["windows", "session", "freshness"]) == "stale"
      refute get_in(deepseek, ["windows", "weekly"])
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
  end

  test "a provider with no durable record stays unknown on the deck" do
    dir = Path.join(System.tmp_dir!(), "aiur-sd-durable-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    workflow_path = Path.join(dir, "config.yaml")
    previous_path = Application.get_env(:aiur, :workflow_file_path)

    try do
      Application.put_env(:aiur, :workflow_file_path, workflow_path)

      view =
        StreamdeckProjection.provider_meters(
          %{deepseek: %{state: :unknown, observed_at: nil, freshness: :unknown, windows: %{}}},
          @now
        )

      assert view["deepseek"]["state"] == "unknown"
      assert view["deepseek"]["windows"] == %{}
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
  end

  # A real observation wins over the durable fallback: the fallback exists to
  # cover an unobserved meter, so an observed one must never be downgraded to
  # the stale ledger value.
  test "a real observation replaces the durable fallback" do
    dir = Path.join(System.tmp_dir!(), "aiur-sd-durable-observed-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    workflow_path = Path.join(dir, "config.yaml")
    previous_path = Application.get_env(:aiur, :workflow_file_path)

    try do
      Application.put_env(:aiur, :workflow_file_path, workflow_path)

      :ok =
        Aiur.ModelAvailability.observe(
          "deepseek",
          %{weekly: %{used: 99, limit: 100}},
          now: ~U[2026-08-02 08:53:00Z]
        )

      view =
        StreamdeckProjection.provider_meters(
          %{deepseek: observed_meter("session", 25, 120, "weekly", 45, 10_080)},
          @now
        )

      assert view["deepseek"]["state"] == "observed"
      assert view["deepseek"]["freshness"] == "fresh"
      assert get_in(view, ["deepseek", "windows", "session", "used_percent"]) == 25
      assert get_in(view, ["deepseek", "windows", "weekly", "used_percent"]) == 45
    after
      restore_app_env(:aiur, :workflow_file_path, previous_path)
      File.rm_rf(dir)
    end
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

  defp credit_window(used_percent, observed_at) do
    %{
      kind: :credit,
      used_percent: used_percent,
      remaining: 10.93,
      observed_at: observed_at,
      freshness: :fresh
    }
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
