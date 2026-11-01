defmodule Aiur.ProviderMeterProbeAccountsTest do
  # These cases share provider events and the account-reading cache.
  use ExUnit.Case, async: false

  alias Aiur.Accounts.UsageReadings
  alias Aiur.ProviderMeterProbe
  alias Aiur.ProviderMeterProjection
  alias Aiur.ProviderMeters.{CLI, Events}
  alias Aiur.ProviderMeterSnapshot

  defmodule MultiWindowUsageApi do
    @moduledoc false
    def fetch(_opts) do
      {:ok,
       %{
         used_percent: 21,
         resets_at: ~U[2026-09-01 18:00:00Z],
         window: "five_hour",
         windows: [
           %{
             window: "seven_day",
             label: "Weekly (all models)",
             scope: :weekly,
             priority: 0,
             coverage: :supported,
             used_percent: 5,
             resets_at: ~U[2026-09-03 18:00:00Z]
           },
           %{
             window: "five_hour",
             label: "Session (5-hour)",
             scope: :session,
             priority: 3,
             coverage: :supported,
             used_percent: 21,
             resets_at: ~U[2026-09-01 18:00:00Z]
           }
         ]
       }}
    end
  end

  defmodule ConstrainedAccountUsageApi do
    @moduledoc false
    def fetch_with_metadata(opts) do
      named? = opts[:credentials_path] == "/profiles/max/.credentials.json"
      percent = if named?, do: 94, else: 33
      observed_at = if named?, do: ~U[2026-10-01 00:00:00Z], else: ~U[2026-10-01 00:01:00Z]
      {:ok, reading} = MultiWindowUsageApi.fetch([])
      reading = %{reading | windows: Enum.map(reading.windows, fn window -> Map.put(window, :used_percent, if(window.window == "seven_day", do: percent, else: if(named?, do: 10, else: 99))) end)}
      {:ok, reading, %{freshness: :fresh, observed_at: observed_at}}
    end
  end

  defmodule SignedOutUsageApi do
    @moduledoc false
    def fetch(_opts), do: {:error, :no_oauth_token}
  end

  setup do
    UsageReadings.reset()
    on_exit(&UsageReadings.reset/0)
    projection = :"account_probe_proj_#{System.unique_integer([:positive])}"
    start_supervised!({ProviderMeterProjection, [name: projection, subscribe?: false]})
    %{projection: projection}
  end

  defp opts(ctx, extra) do
    Keyword.merge([projection: ctx.projection, backend_configs: %{}], extra)
  end

  test "the older 94 percent account is published as the worst of two for every summary", ctx do
    :ok = Events.subscribe_observed()
    ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: ConstrainedAccountUsageApi, claude_accounts: ["default", "max"], claude_profiles: %{"max" => "/profiles/max"}))
    assert_received {:provider_meter_changed, %ProviderMeterSnapshot{provider: :claude} = snapshot}
    assert snapshot.windows["seven_day"].used_percent == 94
    assert snapshot.observed_at == ~U[2026-10-01 00:00:00Z]
    assert snapshot.summary_label == "worst of 2 accounts · max"
    send(ctx.projection, {:provider_meter_changed, snapshot})
    view = ProviderMeterProjection.provider_view(ctx.projection, :claude)
    assert view.summary_label == "worst of 2 accounts · max"
    assert view.windows["seven_day"].used_percent == 94
    output = ExUnit.CaptureIO.capture_io(fn -> CLI.print({:claude, view}) end)
    assert output =~ "94%"
    assert output =~ "worst of 2 accounts · max"
  end

  test "a failed account makes the summary name the observed account rather than claim the fleet worst", ctx do
    :ok = Events.subscribe_observed()
    ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: MultiWindowUsageApi, claude_accounts: ["default", "missing"]))
    assert_received {:provider_meter_changed, %ProviderMeterSnapshot{provider: :claude} = snapshot}
    assert snapshot.summary_label == "default · 1/2 accounts observed"
    assert snapshot.windows["seven_day"].used_percent == 5
    refute snapshot.summary_label =~ "worst"
  end

  # #7449: a signed-out account used to be skipped with only a log line.
  test "a signed-out account raises one alert naming the login command after three failures, resolved by a good read", ctx do
    test_pid = self()
    alert = fn topic, message, opts -> send(test_pid, {:alert, topic, message, opts}) end

    for _ <- 1..4, do: ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: SignedOutUsageApi, claude_accounts: ["default"], alert_fun: alert))

    assert_received {:alert, "system.claude_account.default.usage_probe_failing", message, opts}
    assert message =~ "not signed in; run `aiur login claude default`"
    assert opts[:needs_attention]
    refute_received {:alert, _topic, _message, _opts}

    [line] = UsageReadings.failure_lines()
    assert line =~ "ACCOUNT claude/default usage probe failing: not signed in; run `aiur login claude default`"
    assert line =~ "4 in a row"

    ProviderMeterProbe.observe(:claude, opts(ctx, usage_api: MultiWindowUsageApi, claude_accounts: ["default"], alert_fun: alert))
    assert_received {:alert, "system.claude_account.default.usage_probe_failing.resolved", _message, resolved_opts}
    refute resolved_opts[:needs_attention]
    assert UsageReadings.failure_lines() == []
  end
end
