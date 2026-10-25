defmodule AiurWeb.RouterAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.{CommandsRedirectController, FinancialDataAccess, Router}

  @supervisor_token String.duplicate("s", 32)
  @dashboard_credentials {"operator", "secret"}
  @session_options Plug.Session.init(store: :cookie, key: "_aiur_test_key", signing_salt: "aiur-test-session")

  setup do
    FinancialDataAccess.Generation.invalidate()

    Aiur.TestSupport.start_owned_endpoint!()

    previous_endpoint = Application.get_env(:aiur, AiurWeb.Endpoint)
    previous_writable = AiurWeb.Endpoint.config(:dashboard_writable)
    original_supervisor_token = System.get_env("AIUR_SUPERVISOR_TOKEN")

    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.merge(previous_endpoint || [], dashboard_auth_required: true))
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)

    on_exit(fn ->
      restore_application_env(AiurWeb.Endpoint, previous_endpoint)

      if Process.whereis(AiurWeb.Endpoint) do
        Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous_writable)
      end

      restore_env("AIUR_SUPERVISOR_TOKEN", original_supervisor_token)
    end)

    :ok
  end

  test "refuses dashboard requests when credentials are not configured" do
    Application.put_env(:aiur, AiurWeb.Endpoint, dashboard_auth_required: false)

    conn = Router.call(dashboard_conn(:get, "/missing", nil), Router.init([]))

    assert conn.status == 503
    assert conn.halted
    assert conn.resp_body =~ "Dashboard authentication is not configured"
  end

  test "requires basic auth when credentials are configured" do
    conn = Router.call(dashboard_conn(:get, "/api/v1/state"), Router.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  test "client-token pipelines preserve optional loopback dashboard authentication" do
    Application.put_env(:aiur, AiurWeb.Endpoint, dashboard_auth_required: false)

    path = Path.join(System.tmp_dir!(), "aiur-loopback-token-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)
    assert {:ok, token} = Aiur.ClientTokens.create("loopback-client", "read")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    conn =
      :get
      |> dashboard_conn("/api/v1/state", nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
  end

  test "event-feed reads use the dashboard authentication pipeline" do
    unauthorized = Router.call(dashboard_conn(:get, "/api/v1/agent-1/events"), Router.init([]))
    assert unauthorized.status == 401

    authorized =
      :get
      |> dashboard_conn("/api/v1/agent-1/events")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert authorized.status == 200
  end

  test "read client tokens authorize reads and cannot call machine write routes" do
    path = Path.join(System.tmp_dir!(), "aiur-router-token-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)
    assert {:ok, token} = Aiur.ClientTokens.create("read-only", "read")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    read =
      :get
      |> dashboard_conn("/api/v1/state", nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert read.status == 200
    assert read.assigns.token_name == "read-only"
    assert read.assigns.token_scope == "read"

    write =
      :post
      |> dashboard_conn("/api/v1/pane/hide", nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert write.status == 403

    assert :ok = Aiur.ClientTokens.revoke("read-only")

    revoked =
      :get
      |> dashboard_conn("/api/v1/state", nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert revoked.status == 401
  end

  test "public API requests reject Basic Auth but accept a client token" do
    Phoenix.Config.put(AiurWeb.Endpoint, :public_bind, true)
    previous_public_bind = Keyword.get(Application.get_env(:aiur, AiurWeb.Endpoint, []), :public_bind)
    path = Path.join(System.tmp_dir!(), "aiur-public-token-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, path)
    assert {:ok, token} = Aiur.ClientTokens.create("public-client", "read")

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Phoenix.Config.put(AiurWeb.Endpoint, :public_bind, previous_public_bind)
      Aiur.TestCleanup.rm_rf!(path)
    end)

    basic =
      :get
      |> dashboard_conn("/api/v1/state")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert basic.status == 401

    bearer =
      :get
      |> dashboard_conn("/api/v1/state", nil)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert bearer.status == 200
  end

  test "event-feed writes return the standard method-not-allowed response" do
    conn =
      :post
      |> dashboard_conn("/api/v1/agent-1/events")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 405
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "method_not_allowed"
  end

  test "pause and resume writes require basic auth" do
    for action <- ["pause", "resume"] do
      response = Router.call(dashboard_conn(:post, "/api/v1/MT-1/#{action}"), Router.init([]))

      assert response.status == 401
      assert get_resp_header(response, "www-authenticate") == ["Basic realm=\"Aiur\""]
    end
  end

  test "fails closed when injected dashboard credentials are absent" do
    conn =
      :post
      |> dashboard_conn("/api/v1/refresh", nil)
      |> Router.dashboard_basic_auth(required?: true)

    assert conn.status == 401
    assert conn.halted
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  test "accepts matching basic auth credentials" do
    conn =
      :get
      |> dashboard_conn("/missing")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end

  test "legacy Commands URLs redirect permanently and preserve detail paths and queries" do
    inbox = redirect_request("/decisions?filter=blocking")
    detail = redirect_request("/decisions/dec%20%2Fsafe?ticket=42")

    assert inbox.status == 301
    assert get_resp_header(inbox, "location") == ["/commands?filter=blocking"]
    assert detail.status == 301
    assert get_resp_header(detail, "location") == ["/commands/dec%20%2Fsafe?ticket=42"]
  end

  test "legacy Commands redirects remain behind dashboard authentication" do
    conn = Router.call(dashboard_conn(:get, "/decisions"), Router.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
  end

  # Old Build Order links (bookmarks, ticket comments, handoff notes) must keep
  # opening the right Build home view after the pages retired.
  test "a Build Order root URL redirects permanently to its imported feature focus" do
    for {path, location} <- [
          {"/build-orders/2573", "/?feature=bo-2573"},
          {"/build-orders/42?view=gantt&x=1", "/?feature=bo-42"},
          {"/build-orders/42?ticket=7", "/?feature=bo-42&ticket=7"}
        ] do
      conn = build_order_request(:get, path)
      assert conn.status == 301, path
      assert get_resp_header(conn, "location") == [location], path
    end
  end

  test "the Build Order catalog URL redirects permanently to the Build home" do
    for {path, location} <- [{"/build-orders", "/"}, {"/build-orders?x=1", "/"}, {"/build-orders?ticket=7", "/?ticket=7"}] do
      conn = build_order_request(:get, path)
      assert conn.status == 301, path
      assert get_resp_header(conn, "location") == [location], path
    end
  end

  test "an invalid Build Order root drops to home and never guesses a feature" do
    for root <- ["01", "abc", "-4", "0", String.duplicate("9", 20), "1%0d%0aSet-Cookie:x", "%2F%2Fevil.example"] do
      conn = build_order_request(:get, "/build-orders/" <> root)
      assert conn.status == 301, root
      assert get_resp_header(conn, "location") == ["/"], root
      refute Enum.any?(get_resp_header(conn, "set-cookie"), &(&1 =~ "x=")), root
    end

    hostile_ticket = build_order_request(:get, "/build-orders/42?ticket=%2F%2Fevil.example")
    assert get_resp_header(hostile_ticket, "location") == ["/?feature=bo-42"]
  end

  test "Build Order redirects stay behind dashboard authentication and answer GET only" do
    unauthenticated = Router.call(dashboard_conn(:get, "/build-orders/42"), Router.init([]))
    assert unauthenticated.status == 401
    assert get_resp_header(unauthenticated, "www-authenticate") == ["Basic realm=\"Aiur\""]
    assert get_resp_header(unauthenticated, "location") == []

    assert build_order_request(:post, "/build-orders/42").status == 404
  end

  test "Decision reads require bearer auth, bypass dashboard Basic Auth, and stay read-only available" do
    System.put_env("AIUR_SUPERVISOR_TOKEN", @supervisor_token)

    missing = Router.call(conn(:get, "/api/v1/decisions"), Router.init([]))
    assert missing.status == 401
    assert get_resp_header(missing, "www-authenticate") == ["Bearer realm=\"Aiur Supervisor\""]

    basic =
      :get
      |> dashboard_conn("/api/v1/decisions")
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
      |> dashboard_conn("/api/v1/pane/hide")
      |> Map.put(:host, "evil.example")
      |> put_req_header("origin", "http://evil.example")
      |> put_req_header("x-aiur-request", "1")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
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
      Enum.reduce(headers, dashboard_conn(:get, "/api/v1/pane/hide"), fn {key, value}, conn ->
        %{conn | req_headers: [{key, value} | conn.req_headers]}
      end)

    conn =
      if get_req_header(conn, "x-aiur-request") == [],
        do: put_req_header(conn, "x-aiur-request", "1"),
        else: conn

    conn
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
    |> Router.call(Router.init([]))
  end

  defp supervisor_request(method, path) do
    method
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{@supervisor_token}")
    |> Router.call(Router.init([]))
  end

  defp dashboard_conn(method, path, credentials \\ @dashboard_credentials) do
    method
    |> conn(path)
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> put_private(:aiur_dashboard_credentials, credentials)
    |> AiurWeb.Session.call(@session_options)
    |> fetch_session()
  end

  defp redirect_request(path), do: CommandsRedirectController.legacy(conn(:get, path), %{})

  defp build_order_request(method, path) do
    method
    |> dashboard_conn(path)
    |> init_test_session(%{})
    |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
    |> Router.call(Router.init([]))
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_application_env(module, nil), do: Application.delete_env(:aiur, module)
  defp restore_application_env(module, value), do: Application.put_env(:aiur, module, value)
end
