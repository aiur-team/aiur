defmodule AiurWeb.RouterAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router

  setup do
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
    end)

    :ok
  end

  test "allows dashboard requests when credentials are not configured" do
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    conn = Router.call(conn(:get, "/missing"), Router.init([]))

    assert conn.status == 404
  end

  test "requires basic auth when credentials are configured" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    conn = Router.call(conn(:get, "/api/v1/state"), Router.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  test "accepts matching basic auth credentials" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    conn =
      :get
      |> conn("/missing")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end

  test "write API accepts exact loopback origins and a path-bearing Referer" do
    assert write_route_get(origin: "http://localhost").status == 405
    assert write_route_get(origin: "http://localhost:80").status == 405
    assert write_route_get(origin: "http://127.0.0.1").status == 405
    assert write_route_get(referer: "http://localhost/dashboard?tab=decisions").status == 405
  end

  test "write API rejects lookalike, malformed, and non-origin Origin values" do
    invalid_origins = [
      "http://localhost.example",
      "http://127.0.0.1.evil",
      "http://localhost@evil.example",
      "http://localhost/path",
      "http://localhost?next=evil",
      "http://localhost#fragment",
      "http://localhost:4444",
      "not a uri"
    ]

    for origin <- invalid_origins do
      conn = write_route_get(origin: origin)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"error" => "origin not allowed"}
    end
  end

  test "write API rejects duplicate Origin and Referer headers" do
    duplicate_origin =
      write_route_get(
        headers: [
          {"origin", "http://localhost"},
          {"origin", "http://localhost"}
        ]
      )

    duplicate_referer =
      write_route_get(
        headers: [
          {"referer", "http://localhost/a"},
          {"referer", "http://localhost/b"}
        ]
      )

    assert duplicate_origin.status == 403
    assert duplicate_referer.status == 403
  end

  defp write_route_get(opts) do
    headers =
      cond do
        headers = Keyword.get(opts, :headers) -> headers
        origin = Keyword.get(opts, :origin) -> [{"origin", origin}]
        referer = Keyword.get(opts, :referer) -> [{"referer", referer}]
      end

    conn =
      Enum.reduce(headers, conn(:get, "/api/v1/pane/hide"), fn {key, value}, conn ->
        %{conn | req_headers: [{key, value} | conn.req_headers]}
      end)

    conn
    |> put_req_header("x-aiur-request", "1")
    |> Router.call(Router.init([]))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
