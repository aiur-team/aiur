defmodule AiurWeb.TrustedProxyTest do
  use ExUnit.Case, async: true

  alias AiurWeb.TrustedProxy

  test "forwarded scheme, host, and client IP apply only to a trusted peer" do
    request =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header("x-forwarded-host", "dashboard.example.com")
      |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.9, 10.0.0.3")
      |> Map.put(:remote_ip, {10, 0, 0, 2})

    untrusted = TrustedProxy.apply_forwarded_headers(request, ["192.0.2.0/24"])
    assert untrusted.scheme == :http
    assert untrusted.host == "www.example.com"
    assert untrusted.remote_ip == {10, 0, 0, 2}

    trusted = TrustedProxy.apply_forwarded_headers(request, ["10.0.0.0/8"])
    assert trusted.scheme == :https
    assert trusted.host == "dashboard.example.com"
    assert trusted.port == 443
    assert trusted.remote_ip == {198, 51, 100, 9}
  end

  test "platform trust accepts private proxy peers and rejects public peers" do
    assert TrustedProxy.trusted?({10, 1, 2, 3}, ["platform"])
    refute TrustedProxy.trusted?({198, 51, 100, 3}, ["platform"])
  end
end
