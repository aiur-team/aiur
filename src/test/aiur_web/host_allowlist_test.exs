defmodule AiurWeb.HostAllowlistTest do
  use Aiur.TestSupport, async: true

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.HostAllowlist

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  test "rejects a foreign Host before downstream endpoint plugs" do
    EndpointStubs.put(allowed_hosts: ["dashboard.example"], allow_tailnet_hosts: false)
    conn = Plug.Test.conn(:get, "/") |> then(&%{&1 | host: "attacker.example"})
    conn = HostAllowlist.call(conn, [])

    assert conn.status == 403
    assert conn.halted
    assert conn.resp_body == "Forbidden"
  end

  test "rejects a foreign Host before Phoenix socket dispatch" do
    EndpointStubs.put(allowed_hosts: ["dashboard.example"], allow_tailnet_hosts: false)
    conn = Plug.Test.conn(:get, "/live/websocket") |> then(&%{&1 | host: "attacker.example"})

    assert AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([])).status == 403
  end

  test "accepts an allowlisted Host with a port" do
    EndpointStubs.put(allowed_hosts: ["dashboard.example"], allow_tailnet_hosts: false)
    conn = Plug.Test.conn(:get, "/") |> then(&%{&1 | host: "dashboard.example"})

    assert %Plug.Conn{halted: false} = HostAllowlist.call(conn, [])
  end

  test "allows configured public hosts and loopback with request ports" do
    assert HostAllowlist.allowed_hosts("https://dashboard.example.com") ==
             ["dashboard.example.com", "localhost", "127.0.0.1", "[::1]", "::1"]
  end

  test "configured hosts are additive to the public URL and loopback defaults" do
    assert HostAllowlist.allowed_hosts("https://dashboard.example.com", ["extra.example"]) ==
             ["dashboard.example.com", "localhost", "127.0.0.1", "[::1]", "::1", "extra.example"]
  end

  test "loopback listeners accept tailnet Host names while loopback-bound" do
    EndpointStubs.put(allowed_hosts: ["*.ts.net"], allow_tailnet_hosts: true)
    conn = Plug.Test.conn(:get, "/") |> then(&%{&1 | host: "orangekid.tailnet-name.ts.net"})

    assert %Plug.Conn{halted: false} = HostAllowlist.call(conn, [])
    refute "*.ts.net" in HostAllowlist.allowed_hosts(nil)
    assert "*.ts.net" in HostAllowlist.allowed_hosts(nil, nil, true)
  end

  test "the authenticated GitHub webhook route accepts its separate tunnel Host" do
    EndpointStubs.put(allowed_hosts: ["dashboard.example"], allow_tailnet_hosts: false)
    conn = Plug.Test.conn(:post, "/api/v1/github/webhook") |> then(&%{&1 | host: "hooks.aiur.dev"})

    assert %Plug.Conn{halted: false} = HostAllowlist.call(conn, [])
  end

  test "derives websocket origins from the public URL and loopback" do
    assert HostAllowlist.origins("https://dashboard.example.com:8443") == [
             "https://dashboard.example.com:8443",
             "//localhost",
             "//127.0.0.1",
             "//[::1]"
           ]
  end
end
