defmodule AiurWeb.RouterAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router

  @supervisor_token String.duplicate("s", 32)

  setup do
    original_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    original_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    original_supervisor_token = System.get_env("AIUR_SUPERVISOR_TOKEN")

    on_exit(fn ->
      restore_env("AIUR_DASHBOARD_USERNAME", original_username)
      restore_env("AIUR_DASHBOARD_PASSWORD", original_password)
      restore_env("AIUR_SUPERVISOR_TOKEN", original_supervisor_token)
    end)

    :ok
  end

  test "refuses dashboard requests when credentials are not configured" do
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    conn = Router.call(conn(:get, "/missing"), Router.init([]))

    assert conn.status == 503
    assert conn.halted
    assert conn.resp_body =~ "Dashboard authentication is not configured"
  end

  test "requires basic auth when credentials are configured" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    conn = Router.call(conn(:get, "/api/v1/state"), Router.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  test "event-feed reads use the dashboard authentication pipeline" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    unauthorized = Router.call(conn(:get, "/api/v1/agent-1/events"), Router.init([]))
    assert unauthorized.status == 401

    authorized =
      :get
      |> conn("/api/v1/agent-1/events")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert authorized.status == 200
  end

  test "event-feed writes return the standard method-not-allowed response" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    conn =
      :post
      |> conn("/api/v1/agent-1/events")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 405
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "method_not_allowed"
  end

  test "pause and resume writes require basic auth" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    for action <- ["pause", "resume"] do
      response = Router.call(conn(:post, "/api/v1/MT-1/#{action}"), Router.init([]))

      assert response.status == 401
      assert get_resp_header(response, "www-authenticate") == ["Basic realm=\"Aiur\""]
    end
  end

  test "fails closed when writable dashboard credentials disappear after startup" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")

    System.delete_env("AIUR_DASHBOARD_PASSWORD")

    conn =
      :post
      |> conn("/api/v1/refresh")
      |> Router.dashboard_basic_auth(required?: true)

    assert conn.status == 401
    assert conn.halted
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

  test "Decision reads require bearer auth, bypass dashboard Basic Auth, and stay read-only available" do
    System.put_env("AIUR_DASHBOARD_USERNAME", "operator")
    System.put_env("AIUR_DASHBOARD_PASSWORD", "secret")
    System.put_env("AIUR_SUPERVISOR_TOKEN", @supervisor_token)

    missing = Router.call(conn(:get, "/api/v1/decisions"), Router.init([]))
    assert missing.status == 401
    assert get_resp_header(missing, "www-authenticate") == ["Bearer realm=\"Aiur Supervisor\""]

    basic =
      :get
      |> conn("/api/v1/decisions")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert basic.status == 401

    authorized = supervisor_request(:get, "/api/v1/decisions")
    assert authorized.status == 200
    assert is_list(Jason.decode!(authorized.resp_body)["decisions"])

    missing_decision = supervisor_request(:get, "/api/v1/decisions/dec_missing")
    assert missing_decision.status == 404
    assert Jason.decode!(missing_decision.resp_body)["error"]["code"] == "decision_not_found"
  end

  test "Decision mutations authenticate before the existing origin and writable gates" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @supervisor_token)
    path = "/api/v1/decisions/dec_known/decide"

    unauthenticated = Router.call(conn(:post, path), Router.init([]))
    assert unauthenticated.status == 401

    authenticated = supervisor_request(:post, path)
    assert authenticated.status == 403
    assert Jason.decode!(authenticated.resp_body) == %{"error" => "origin not allowed"}

    read_only =
      :post
      |> conn(path)
      |> put_req_header("authorization", "Bearer #{@supervisor_token}")
      |> put_req_header("origin", "http://localhost")
      |> put_req_header("x-aiur-request", "1")
      |> Router.call(Router.init([]))

    assert read_only.status == 403
    assert Jason.decode!(read_only.resp_body) == %{"error" => "dashboard is read-only"}
  end

  test "Decision route method catches cannot fall through to generic issue reads" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @supervisor_token)

    for {method, path} <- [
          {:post, "/api/v1/decisions"},
          {:patch, "/api/v1/decisions/dec_known"},
          {:get, "/api/v1/decisions/dec_known/enrich"},
          {:delete, "/api/v1/decisions/dec_known/decide"},
          {:put, "/api/v1/decisions/dec_known/revise"}
        ] do
      response = supervisor_request(method, path)
      assert response.status == 405
      assert Jason.decode!(response.resp_body)["error"]["code"] == "method_not_allowed"
    end
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

  test "write API does not trust an attacker-controlled Host as its own origin" do
    conn =
      :get
      |> conn("/api/v1/pane/hide")
      |> Map.put(:host, "evil.example")
      |> put_req_header("origin", "http://evil.example")
      |> put_req_header("x-aiur-request", "1")
      |> Router.call(Router.init([]))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "origin not allowed"}
  end

  test "write API rejects duplicate Origin, Referer, and custom headers" do
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

    duplicate_custom =
      write_route_get(
        headers: [
          {"origin", "http://localhost"},
          {"x-aiur-request", "1"},
          {"x-aiur-request", "1"}
        ]
      )

    assert duplicate_origin.status == 403
    assert duplicate_referer.status == 403
    assert duplicate_custom.status == 403
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

    conn =
      if get_req_header(conn, "x-aiur-request") == [],
        do: put_req_header(conn, "x-aiur-request", "1"),
        else: conn

    Router.call(conn, Router.init([]))
  end

  defp supervisor_request(method, path) do
    method
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{@supervisor_token}")
    |> Router.call(Router.init([]))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
