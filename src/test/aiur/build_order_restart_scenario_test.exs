defmodule Aiur.BuildOrderRestartScenarioTest do
  @moduledoc """
  Exercises the startup health-check path with the dashboard port changing
  across a restart while the persisted Funnel target remains unchanged.
  """

  use ExUnit.Case, async: true

  alias Aiur.BuildOrderFunnelHealth

  test "restart with an old Funnel target returns an actionable mismatch" do
    old_port = 41_513
    new_port = 41_514
    status_json = Jason.encode!(funnel_status(old_port))
    alerts = self()

    opts = [
      bound_port: new_port,
      http_client: fn url, timeout ->
        send(alerts, {:endpoint_probe, url, timeout})
        {:ok, %Req.Response{status: 401}}
      end,
      tailscale_executable: "/fake/tailscale",
      tailscale_runner: fn "/fake/tailscale", ["funnel", "status", "--json"], timeout ->
        send(alerts, {:tailscale_probe, timeout})
        {status_json, 0}
      end,
      alert: fn failure -> send(alerts, {:alert, failure}) end
    ]

    failure = %{cause: :funnel_target_mismatch, reasons: [{:target_port, old_port}]}
    assert {:error, ^failure} = BuildOrderFunnelHealth.check(opts)
    assert_received {:endpoint_probe, "http://127.0.0.1:41514/build-orders/1", 5_000}
    assert_received {:tailscale_probe, 5_000}
    assert_received {:alert, ^failure}
    refute_received {:alert, %{cause: :unknown}}
  end

  test "same-port restart returns healthy without an alert" do
    current_port = 41_514

    assert {:ok, ^current_port} =
             BuildOrderFunnelHealth.check(
               bound_port: current_port,
               http_client: fn _url, _timeout -> {:ok, %Req.Response{status: 200}} end,
               funnel_status: funnel_status(current_port),
               alert: fn failure -> send(self(), {:alert, failure}) end
             )

    refute_received {:alert, _failure}
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
