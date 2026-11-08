defmodule AiurWeb.GatewayHelloControllerTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  @path "/api/v1/gateway/hello"

  setup context do
    config = Application.get_env(:aiur, Endpoint)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(config || [], server: false, gateway_hello: Map.get(context, :hello, true), dashboard_auth_required: true, secret_key_base: String.duplicate("s", 64))
    )

    Aiur.TestSupport.start_owned_endpoint!()
    on_exit(fn -> Application.put_env(:aiur, Endpoint, config) end)
    :ok
  end

  test "answers with no credential and exactly the five keys" do
    conn = get(build_conn(), @path)
    assert conn.status == 200
    body = json_response(conn, 200)
    assert Enum.sort(Map.keys(body)) == Enum.sort(~w(gateway_id gateway_label build tls_fingerprint_sha256 enrollment))
    assert body["enrollment"] == "closed"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  @tag hello: false
  test "answers 404 when server.gateway_hello is off" do
    assert get(build_conn(), @path).status == 404
  end

  test "POST is 405 with allow: GET, and other api paths still need a credential" do
    conn = post(build_conn(), @path)
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["GET"]
    assert get(build_conn(), "/api/v1/state").status == 401
  end
end
