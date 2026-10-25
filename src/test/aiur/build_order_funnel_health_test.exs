defmodule Aiur.BuildOrderFunnelHealthTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrderFunnelHealth

  describe "startup health check" do
    test "accepts the authenticated endpoint when Funnel targets the current port" do
      assert {:ok, 4_000} =
               BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000)))

      assert_received {:http_request, "http://127.0.0.1:4000/build-orders/1", 5_000}
      refute_received {:health_alert, _failure}
    end

    test "reports the persisted old target after the dashboard port changes" do
      failure = %{cause: :funnel_target_mismatch, reasons: [{:target_port, 41_513}]}

      assert {:error, ^failure} =
               BuildOrderFunnelHealth.check(check_opts(41_514, funnel_status(41_513)))

      assert_received {:health_alert, ^failure}
    end

    test "probes a tailnet-only bound host rather than assuming loopback" do
      assert {:ok, 4_000} =
               BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000), bound_host: "100.89.1.2"))

      assert_received {:http_request, "http://100.89.1.2:4000/build-orders/1", 5_000}
    end

    test "maps wildcard binds to loopback for the local health probe" do
      assert {:ok, 4_000} =
               BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000), bound_host: "::"))

      assert_received {:http_request, "http://127.0.0.1:4000/build-orders/1", 5_000}
    end

    test "keeps a failed tailscale exit as an unknown cause with its exit status" do
      runner = fn "/fake/tailscale", ["funnel", "status", "--json"], 5_000 -> {"denied", 2} end
      failure = %{cause: :unknown, reasons: [{:tailscale_exit, 2}]}

      assert {:error, ^failure} =
               BuildOrderFunnelHealth.check(
                 check_opts(4_000, nil,
                   tailscale_executable: "/fake/tailscale",
                   tailscale_runner: runner
                 )
               )

      assert_received {:health_alert, ^failure}
    end

    test "keeps invalid Tailscale JSON separate from a genuine target mismatch" do
      runner = fn _executable, _args, _timeout -> {"{broken", 0} end
      failure = %{cause: :unknown, reasons: [:invalid_status_json]}

      assert {:error, ^failure} =
               BuildOrderFunnelHealth.check(
                 check_opts(4_000, nil,
                   tailscale_executable: "/fake/tailscale",
                   tailscale_runner: runner
                 )
               )

      assert_received {:health_alert, ^failure}
    end

    test "reports a missing root proxy handler as an unknown status reason" do
      status = %{
        "AllowFunnel" => %{"dashboard.example.ts.net:443" => true},
        "Web" => %{"dashboard.example.ts.net:443" => %{"Handlers" => %{}}}
      }

      assert {:error, %{cause: :unknown, reasons: [:funnel_443_root_proxy_missing]}} =
               BuildOrderFunnelHealth.funnel_target_status(status, 4_000)
    end

    test "accepts only the documented HTTP status set" do
      for status <- [201, 204, 303, 502, 503] do
        assert {:error, %{cause: :unreachable, reasons: [{:http_status, ^status}]}} =
                 BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000), http_client: fn _url, _timeout -> {:ok, %Req.Response{status: status}} end))
      end
    end

    test "does not label connection refusal as a timeout" do
      assert {:error, %{cause: :unknown, reasons: [{:transport, :econnrefused}]}} =
               BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000), http_client: fn _url, _timeout -> {:error, :econnrefused} end))
    end

    test "does not query Funnel when the endpoint probe times out" do
      runner = fn _executable, _args, _timeout -> flunk("Tailscale must not run after an endpoint timeout") end

      assert {:error, %{cause: :timeout, reasons: [{:transport, :timeout}]}} =
               BuildOrderFunnelHealth.check(
                 check_opts(4_000, nil,
                   http_client: fn _url, _timeout -> {:error, :timeout} end,
                   tailscale_executable: "/fake/tailscale",
                   tailscale_runner: runner
                 )
               )
    end

    test "keeps an HTTP client exception under the unknown cause" do
      assert {:error, %{cause: :unknown, reasons: [{:http_client_exception, RuntimeError}]}} =
               BuildOrderFunnelHealth.check(check_opts(4_000, funnel_status(4_000), http_client: fn _url, _timeout -> raise "synthetic client failure" end))
    end

    test "ignores an explicitly disabled Funnel status" do
      assert :not_configured = BuildOrderFunnelHealth.funnel_target_status(%{"AllowFunnel" => %{}}, 4_000)
    end
  end

  defp check_opts(port, status, extra \\ []) do
    defaults = [
      bound_port: port,
      bound_host: "127.0.0.1",
      http_client: fn url, timeout ->
        send(self(), {:http_request, url, timeout})
        {:ok, %Req.Response{status: 401}}
      end,
      alert: fn failure -> send(self(), {:health_alert, failure}) end
    ]

    defaults
    |> maybe_put_funnel_status(status)
    |> Keyword.merge(extra)
  end

  defp maybe_put_funnel_status(opts, nil), do: opts
  defp maybe_put_funnel_status(opts, status), do: Keyword.put(opts, :funnel_status, status)

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
