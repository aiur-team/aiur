defmodule AiurWeb.Build.UsageAPIsProviderRowsTest do
  use ExUnit.Case, async: true

  alias Aiur.Usage.Provider.Fal
  alias AiurWeb.Build.UsageAPIs

  test "provider usage bars keep an unavailable reading unknown" do
    rows =
      UsageAPIs.provider_rows(
        %{
          fal: %{
            provider: :fal,
            observed_at: nil,
            fields: %{state: :unavailable, reason: :transport, actual: nil, estimate: nil, balance: nil, reset_at: nil}
          }
        },
        System.system_time(:millisecond)
      )

    assert [%{name: "fal.ai", lines: [%{acc: [nil], reset_at: nil, tip: tip}]}] = rows
    assert [balance, actual, estimate | _metadata] = tip
    assert balance == ["Balance", "unknown"]
    assert actual == ["Actual balance", "unknown"]
    assert estimate == ["Estimated balance", "unknown"]
  end

  test "populated provider bars show actual values, reset, period, age, and freshness" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reset = DateTime.add(now, 3_600, :second)
    now_ms = DateTime.to_unix(now, :millisecond)

    fal =
      Fal.read(
        now: now,
        fal_usage: {:ok, %{actual: 24.5, balance: 24.5, estimate: nil, currency: "USD", reset_at: nil, period: "current balance", observed_at: now}}
      )

    [fal_row] = UsageAPIs.provider_rows(%{fal: fal}, now_ms)
    assert fal_row.name == "fal.ai"
    assert [fal_line] = fal_row.lines
    assert fal_line.acc == [nil]
    assert ["Actual balance", "24.5 USD"] in fal_line.tip
    assert ["Estimated balance", "unknown"] in fal_line.tip
    assert ["Observed age", "0s"] in fal_line.tip
    assert ["Freshness", "fresh"] in fal_line.tip

    github = {:ok, %{state: :observed, windows: %{}, backoffs: []}}
    elevenlabs = %{state: :observed, observed_at: now, window: %{used: 30, limit: 100, remaining: 70, used_percent: 30, reset_at: reset}}
    [_, elevenlabs_row] = UsageAPIs.rows(github, elevenlabs, now_ms)
    assert elevenlabs_row.name == "ElevenLabs"
    assert [elevenlabs_line] = elevenlabs_row.lines
    assert elevenlabs_line.acc == [70]
    assert elevenlabs_line.reset_at == DateTime.to_unix(reset, :millisecond)
    assert ["Characters used", "30"] in elevenlabs_line.tip
    assert ["Quota", "100"] in elevenlabs_line.tip
    assert ["Period", "character quota"] in elevenlabs_line.tip
    assert ["Observed age", "0s"] in elevenlabs_line.tip
    assert ["Freshness", "fresh"] in elevenlabs_line.tip
  end
end
