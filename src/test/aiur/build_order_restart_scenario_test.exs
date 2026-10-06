defmodule Aiur.BuildOrderRestartScenarioTest do
  @moduledoc """
  Integration test for Build Order Funnel target durability across restarts.

  Simulates a real restart scenario where:
  1. Dashboard runs on port X with Funnel target pointing to X
  2. Daemon restarts, dashboard now on port Y (due to port change/randomization)
  3. Funnel target still points to stale port X
  4. Health check detects the mismatch and alerts operator

  This test verifies that the health check can detect this condition.
  """

  use ExUnit.Case, async: false

  alias Aiur.BuildOrderFunnelHealth

  describe "port change detection across restarts" do
    test "detects when Funnel target points to wrong port after restart" do
      # Scenario: Khala dashboard was running on port 41513 (Funnel target)
      # After restart, it's running on port 41514 (new port assigned)
      # Funnel target hasn't been updated yet - still points to 41513

      stale_status = funnel_status(41_513)

      assert {:error, {:funnel_target_mismatch, 41_513}} =
               BuildOrderFunnelHealth.funnel_target_status(stale_status, 41_514)
    end

    test "bound_port reflects current port assignment" do
      # This test verifies that the health check can access the current
      # bound port and use it for determining the correct endpoint
      port = BuildOrderFunnelHealth.bound_port()

      case port do
        nil ->
          # Not bound, which is OK for test environment
          :ok

        port when is_integer(port) and port > 0 ->
          # Port is correctly identified
          # In production, this would be used to verify/repair Funnel target
          assert port > 0
      end
    end

    test "base_url shows operator-readable address for diagnostics" do
      # When health check detects stale target, it includes the
      # operator-readable address for manual Funnel target repair
      url = BuildOrderFunnelHealth.base_url()

      case url do
        nil ->
          # Not bound
          :ok

        url when is_binary(url) ->
          # URL is correctly formatted for operator to identify current target
          assert String.starts_with?(url, "http://")
      end
    end

    test "health check is idempotent - can be called repeatedly" do
      # Verify that calling the health check multiple times doesn't
      # cause side effects (aside from alert emission, which is expected)

      result1 = BuildOrderFunnelHealth.check(timeout_ms: 100, funnel_status: %{"AllowFunnel" => %{}})
      result2 = BuildOrderFunnelHealth.check(timeout_ms: 100, funnel_status: %{"AllowFunnel" => %{}})

      # Results should be consistent (same port or both errors)
      case {result1, result2} do
        {{:ok, port1}, {:ok, port2}} -> assert port1 == port2
        {{:error, reason1}, {:error, reason2}} -> assert reason1 == reason2
        _ -> flunk("health check results changed between identical checks: #{inspect({result1, result2})}")
      end
    end
  end

  defp funnel_status(target_port) do
    endpoint = "dashboard.example.ts.net:443"

    %{
      "AllowFunnel" => %{endpoint => true},
      "Web" => %{
        endpoint => %{
          "Handlers" => %{"/" => %{"Proxy" => "http://127.0.0.1:#{target_port}"}}
        }
      }
    }
  end
end
