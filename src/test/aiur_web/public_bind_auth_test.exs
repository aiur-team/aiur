defmodule AiurWeb.PublicBindAuthTest do
  use ExUnit.Case, async: false

  alias Aiur.Config.Schema
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.{DashboardAuthRateLimit, Endpoint, PublicBindGuard}

  test "a public bind requires browser Basic Auth off and a usable sign-in method" do
    assert {:ok, basic_only} = Schema.parse(%{})
    refute Aiur.HttpServer.public_browser_auth_ready?(basic_only, passkeys_enrolled?: true)

    assert {:ok, google} =
             Schema.parse(%{
               "server" => %{"public_url" => "https://dashboard.example.com"},
               "dashboard_auth" => %{
                 "browser_basic_auth" => false,
                 "google" => %{"allowed_emails" => ["operator@example.com"]}
               }
             })

    assert Aiur.HttpServer.public_browser_auth_ready?(google, google_client_id: "client", google_client_secret: "secret")
    refute Aiur.HttpServer.public_browser_auth_ready?(google, google_client_id: "", google_client_secret: "secret")
    assert Aiur.HttpServer.public_browser_auth_ready?(google, passkeys_enrolled?: true)

    assert {:ok, browser_basic_enabled} =
             Schema.parse(%{
               "server" => %{"public_url" => "https://dashboard.example.com"},
               "dashboard_auth" => %{
                 "browser_basic_auth" => true,
                 "google" => %{"allowed_emails" => ["operator@example.com"]}
               }
             })

    refute Aiur.HttpServer.public_browser_auth_ready?(browser_basic_enabled,
             google_client_id: "client",
             google_client_secret: "secret",
             passkeys_enrolled?: true
           )
  end

  test "only health, sign-in, passkey, and the signed webhook request paths bypass public auth" do
    for {method, path} <- [
          {"GET", ["healthz"]},
          {"GET", ["readyz"]},
          {"GET", ["auth", "login"]},
          {"GET", ["auth", "google", "callback"]},
          {"POST", ["auth", "passkeys", "authentication", "finish"]},
          {"POST", ["api", "v1", "github", "webhook"]}
        ] do
      assert PublicBindGuard.public_path?(%Plug.Conn{method: method, path_info: path})
    end

    refute PublicBindGuard.public_path?(%Plug.Conn{method: "GET", path_info: ["api", "v1", "state"]})
    refute PublicBindGuard.public_path?(%Plug.Conn{method: "POST", path_info: ["auth", "logout"]})
    refute PublicBindGuard.public_path?(%Plug.Conn{method: "POST", path_info: ["api", "v1", "github", "webhook", "extra"]})
  end

  test "router routes return unauthenticated 2xx only for the explicit public path set" do
    previous_username = System.get_env("AIUR_DASHBOARD_USERNAME")
    previous_password = System.get_env("AIUR_DASHBOARD_PASSWORD")
    previous_endpoint_config = Application.get_env(:aiur, AiurWeb.Endpoint)
    System.delete_env("AIUR_DASHBOARD_USERNAME")
    System.delete_env("AIUR_DASHBOARD_PASSWORD")
    endpoint_config = previous_endpoint_config || []
    Application.put_env(:aiur, AiurWeb.Endpoint, Keyword.put(endpoint_config, :dashboard_auth_required, false))

    on_exit(fn ->
      if previous_username, do: System.put_env("AIUR_DASHBOARD_USERNAME", previous_username), else: System.delete_env("AIUR_DASHBOARD_USERNAME")
      if previous_password, do: System.put_env("AIUR_DASHBOARD_PASSWORD", previous_password), else: System.delete_env("AIUR_DASHBOARD_PASSWORD")

      case previous_endpoint_config do
        nil -> Application.delete_env(:aiur, AiurWeb.Endpoint)
        config -> Application.put_env(:aiur, AiurWeb.Endpoint, config)
      end
    end)

    EndpointStubs.put(
      public_bind: true,
      # Disable ordinary router auth so this walk proves the endpoint guard
      # protects paths that router pipelines do not.
      dashboard_auth_required: false,
      browser_basic_auth: true,
      allowed_hosts: ["www.example.com"]
    )

    unknown =
      Plug.Test.conn(:get, "/__public_bind_guard_probe__")
      |> Plug.Test.init_test_session(%{})
      |> then(&AiurWeb.Endpoint.call(&1, AiurWeb.Endpoint.init([])))

    assert unknown.status in [401, 302]

    if unknown.status == 302 do
      assert Plug.Conn.get_resp_header(unknown, "location") == ["/auth/login"]
    end

    for route <- Phoenix.Router.routes(AiurWeb.Router) do
      path = Regex.replace(~r/[:*][^\/]+/, route.path, "fixture")
      method = "GET"
      conn = Plug.Test.conn(:get, path) |> Plug.Test.init_test_session(%{})

      response = AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))
      expected_path = String.split(path, "/", trim: true)
      public? = PublicBindGuard.public_path?(%Plug.Conn{method: method, path_info: expected_path})

      if response.status in 200..299 do
        assert public?, "unexpected unauthenticated success for #{route.path}"
      end

      unless public? do
        assert response.status in [401, 302], "public bind returned #{response.status} without auth for #{route.path}"
      end
    end
  end

  test "public-bind guard leaves Decision API authentication to SupervisorAuth" do
    previous_token = System.get_env("AIUR_SUPERVISOR_TOKEN")
    token = String.duplicate("s", 32)
    System.put_env("AIUR_SUPERVISOR_TOKEN", token)

    on_exit(fn ->
      if previous_token, do: System.put_env("AIUR_SUPERVISOR_TOKEN", previous_token), else: System.delete_env("AIUR_SUPERVISOR_TOKEN")
    end)

    EndpointStubs.put(
      public_bind: true,
      dashboard_auth_required: true,
      browser_basic_auth: false,
      allowed_hosts: ["www.example.com"]
    )

    missing = Endpoint.call(Plug.Test.conn(:get, "/api/v1/decisions"), Endpoint.init([]))
    assert missing.status == 401
    assert Plug.Conn.get_resp_header(missing, "www-authenticate") == ["Bearer realm=\"Aiur Supervisor\""]

    authorized =
      Plug.Test.conn(:get, "/api/v1/decisions")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> then(&Endpoint.call(&1, Endpoint.init([])))

    assert authorized.status == 200
  end

  test "sign-in routes rate limit repeated attempts by client IP" do
    start_store()
    ip = {203, 0, 113, 201}

    responses =
      for _ <- 1..21 do
        Plug.Test.conn(:post, "/auth/passkeys/authentication/finish")
        |> Map.put(:remote_ip, ip)
        |> DashboardAuthRateLimit.call([])
      end

    assert Enum.at(responses, 19).halted == false
    assert Enum.at(responses, 20).status == 429
    assert Enum.at(responses, 20).halted
  end

  defp start_store do
    case Process.whereis(DashboardAuthRateLimit.Store) do
      nil ->
        {:ok, pid} = DashboardAuthRateLimit.Store.start_link()
        ExUnit.Callbacks.on_exit(fn -> stop_store(pid) end)

      _pid ->
        :ok
    end
  end

  defp stop_store(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  end
end
