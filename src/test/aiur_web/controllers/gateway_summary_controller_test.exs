defmodule AiurWeb.GatewaySummaryControllerTest do
  use Aiur.TestSupport
  import Phoenix.ConnTest
  import Plug.Conn
  alias AiurWeb.Endpoint
  @endpoint Endpoint

  @listed "https://nook.t.ts.net"
  @path "/api/v1/gateway/summary"

  setup do
    config = Application.get_env(:aiur, Endpoint)

    Application.put_env(
      :aiur,
      Endpoint,
      Keyword.merge(config || [], server: false, dashboard_auth_required: false, dashboard_origins: [@listed], secret_key_base: String.duplicate("s", 64))
    )

    Aiur.TestSupport.start_owned_endpoint!()

    root = Path.join(System.tmp_dir!(), "aiur-gw-summary-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :client_tokens_path)
    Application.put_env(:aiur, :client_tokens_path, Path.join(root, "client-tokens.json"))

    on_exit(fn ->
      Application.put_env(:aiur, Endpoint, config)
      if previous, do: Application.put_env(:aiur, :client_tokens_path, previous), else: Application.delete_env(:aiur, :client_tokens_path)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    :ok
  end

  defp origin(conn, value), do: put_req_header(conn, "origin", value)

  test "preflight from a listed origin echoes it; an unlisted origin gets no CORS headers" do
    conn = build_conn() |> origin(@listed) |> put_req_header("access-control-request-method", "GET") |> options(@path)
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == [@listed]
    assert get_resp_header(conn, "access-control-allow-credentials") == ["true"]

    for bad <- ["https://evil.example", "null", "https://nook.t.ts.net:8443", "https://nook.t.ts.net/"] do
      conn = build_conn() |> origin(bad) |> options(@path)
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-credentials") == []
    end
  end

  test "signed-out GET is a 401 with CORS headers for a listed origin and no Basic challenge" do
    conn = build_conn() |> origin(@listed) |> get(@path)
    assert json_response(conn, 401) == %{"error" => "signed_out"}
    assert get_resp_header(conn, "www-authenticate") == []
    assert get_resp_header(conn, "access-control-allow-origin") == [@listed]

    conn = build_conn() |> origin("https://evil.example") |> get(@path)
    assert conn.status == 401
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "a bad bearer is unauthorized; a valid one gets the summary ahead of the issue catch-all" do
    assert build_conn() |> put_req_header("authorization", "Bearer nope") |> get(@path) |> json_response(401) == %{"error" => "unauthorized"}

    {:ok, token} = Aiur.ClientTokens.create("summary-test", "read")
    body = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(@path) |> json_response(200)

    assert Map.keys(body) |> Enum.sort() ==
             ~w(age_ms capacity connectivity executor_present gateway_id gateway_identity gateway_label observed_at projects workload)
  end

  test "write routes stay same-origin: a listed Origin does not unlock them" do
    conn = build_conn() |> origin(@listed) |> post("/api/v1/refresh")
    assert conn.status in [401, 403]
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
