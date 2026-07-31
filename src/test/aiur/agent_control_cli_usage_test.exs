defmodule Aiur.AgentControlCLIUsageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Aiur.{AgentControlCLI, ProviderMeterProjection}

  setup do
    # Start a private projection rather than fighting the app-supervised one
    # (permanent restart), and inject it into the CLI.
    projection = :"cli_usage_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised({ProviderMeterProjection, [name: projection, subscribe?: false, clock: fn -> ~U[2026-07-27 12:05:00Z] end]})

    %{projection: projection, pid: pid}
  end

  test "a never-observed provider prints as unobserved, never as zero", ctx do
    output = capture_io(fn -> AgentControlCLI.usage(ctx.projection) end)

    assert output =~ "claude  no observation yet"
    assert output =~ "codex   no observation yet"
    refute output =~ "0%"
  end

  test "an observed provider prints a bar, a percentage, and an age", ctx do
    send_observation(ctx.pid, :claude, ~U[2026-07-27 12:00:00Z], %{"session" => window(70)})

    output = capture_io(fn -> AgentControlCLI.usage(ctx.projection) end)

    assert output =~ "claude"
    assert output =~ "70%"
    assert output =~ "5m ago"
    assert output =~ "███████░░░"
  end

  test "an observation with no rate-limit window still names its age", ctx do
    send_observation(ctx.pid, :codex, ~U[2026-07-27 12:04:00Z], %{})

    output = capture_io(fn -> AgentControlCLI.usage(ctx.projection) end)

    assert output =~ "no limit windows reported"
    assert output =~ "1m ago"
  end

  test "a window with no percentage is named unknown rather than drawn as zero", ctx do
    send_observation(ctx.pid, :codex, ~U[2026-07-27 12:04:30Z], %{"session" => %{kind: :rate_limit, name: :primary}})

    output = capture_io(fn -> AgentControlCLI.usage(ctx.projection) end)

    assert output =~ "unknown"
    refute output =~ "0%"
  end

  test "non-rate-limit windows are not reported as limits", ctx do
    send_observation(ctx.pid, :codex, ~U[2026-07-27 12:04:00Z], %{"spend" => %{kind: :budget, used_percent: 90}})

    output = capture_io(fn -> AgentControlCLI.usage(ctx.projection) end)

    assert output =~ "no limit windows reported"
    refute output =~ "90%"
  end

  test "ages scale from seconds through hours", ctx do
    send_observation(ctx.pid, :claude, ~U[2026-07-27 12:04:45Z], %{"s" => window(10)})
    assert capture_io(fn -> AgentControlCLI.usage(ctx.projection) end) =~ "15s ago"

    send_observation(ctx.pid, :codex, ~U[2026-07-27 09:05:00Z], %{"s" => window(10)})
    assert capture_io(fn -> AgentControlCLI.usage(ctx.projection) end) =~ "3h ago"
  end

  test "the bar saturates rather than overflowing" do
    assert AgentControlCLI.usage_bar(0) == String.duplicate("░", 10)
    assert AgentControlCLI.usage_bar(100) == String.duplicate("█", 10)
    assert AgentControlCLI.usage_bar(140) == String.duplicate("█", 10)
    assert AgentControlCLI.usage_bar(-20) == String.duplicate("░", 10)
  end

  defp send_observation(pid, provider, observed_at, windows) do
    snapshot = %Aiur.ProviderMeterSnapshot{
      provider: provider,
      backend: :app_server,
      provider_account_generation: "gen-1",
      observed_at: observed_at,
      auth_mode: :subscription,
      freshness: :fresh,
      health: %{state: :healthy, failure: nil, last_observed_at: observed_at, last_source_version: 1},
      windows: windows
    }

    send(pid, {:provider_meter_changed, snapshot})
    # Force a synchronous round-trip so the send is applied before asserting.
    _ = ProviderMeterProjection.snapshot(pid)
    :ok
  end

  defp window(used_percent), do: %{kind: :rate_limit, used_percent: used_percent, name: :primary}
end
