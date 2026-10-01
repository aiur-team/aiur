defmodule Aiur.Muse.MeterProbeTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.MeterProbe

  test "read-only probe asks for usage/read and reports missing observation" do
    scope = make_ref()

    request = fn method ->
      send(self(), {:requested, method})
      {:ok, %{"result" => %{}}}
    end

    assert {:error, :unavailable} = MeterProbe.read(request, scope)
    assert_received {:requested, "usage/read"}, 1000
  end

  test "native current and weekly windows retain independent reset, age basis and overage" do
    scope = make_ref()
    usage = observation(117, 103)

    assert {:ok, normalized} = MeterProbe.normalize_changed(%{"method" => "usage/changed", "params" => usage}, scope)
    assert normalized.identity == :unverified
    assert normalized.host_scope == scope
    assert normalized.auth_mode == :unknown
    assert normalized.tier == :pro
    assert DateTime.compare(normalized.observed_at, ~U[2026-09-27 12:00:00Z]) == :eq

    assert [current, weekly] = normalized.windows
    assert current.limit_id == "muse.current"
    assert current.name == :current
    assert current.used_percent == 117
    assert DateTime.compare(current.resets_at, ~U[2026-09-27 13:00:00Z]) == :eq
    assert current.duration_minutes == 300
    assert weekly.limit_id == "muse.weekly"
    assert weekly.name == :weekly
    assert weekly.used_percent == 103
    assert DateTime.compare(weekly.resets_at, ~U[2026-10-04 12:00:00Z]) == :eq
    assert weekly.duration_minutes == nil
  end

  test "read result and change notification normalize identically for the same host" do
    scope = make_ref()
    usage = observation(18, 54)

    assert MeterProbe.normalize_read(%{"result" => %{"usage" => usage}}, scope) ==
             MeterProbe.normalize_changed(%{"method" => "usage/changed", "params" => usage}, scope)
  end

  test "malformed or absent observations cannot become zero allowance" do
    scope = make_ref()
    assert {:error, :unavailable} = MeterProbe.normalize_read(%{"result" => %{"usage" => nil}}, scope)

    assert {:error, :invalid_usage_observation} =
             MeterProbe.normalize_read(%{"result" => %{"usage" => observation(-1, 10)}}, scope)
  end

  defp observation(current_percent, weekly_percent) do
    %{
      "observedAtMs" => 1_790_510_400_000,
      "tier" => "pro",
      "window" => %{
        "usedPercent" => current_percent,
        "resetsAtMs" => 1_790_514_000_000,
        "windowDurationMins" => 300
      },
      "weekly" => %{"usedPercent" => weekly_percent, "resetsAtMs" => 1_791_115_200_000}
    }
  end
end
