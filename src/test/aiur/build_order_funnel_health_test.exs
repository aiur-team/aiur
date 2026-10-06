defmodule Aiur.BuildOrderFunnelHealthTest do
  use ExUnit.Case, async: false

  alias Aiur.BuildOrderFunnelHealth

  describe "bound_port and base_url" do
    test "returns current bound port" do
      # Test that these functions exist and can be called
      port = BuildOrderFunnelHealth.bound_port()
      # Port can be nil (not bound) or an integer
      assert port == nil or is_integer(port)
    end

    test "returns base URL or nil" do
      url = BuildOrderFunnelHealth.base_url()
      # URL can be nil (not bound) or a string starting with http
      assert url == nil or String.starts_with?(url, "http")
    end
  end

  describe "persisted Funnel target" do
    test "detects a target left on the old port after a dashboard restart" do
      stale_status = funnel_status(41_513)
      repaired_status = funnel_status(4_000)

      assert {:error, {:funnel_target_mismatch, 41_513}} =
               BuildOrderFunnelHealth.funnel_target_status(stale_status, 4_000)

      assert :ok = BuildOrderFunnelHealth.funnel_target_status(repaired_status, 4_000)
    end

    test "ignores Funnel when it is not enabled" do
      assert :not_configured = BuildOrderFunnelHealth.funnel_target_status(%{"AllowFunnel" => %{}}, 4_000)
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
