defmodule AiurWeb.PublicBindAuthTest do
  use ExUnit.Case, async: true

  alias Aiur.Config.Schema
  alias AiurWeb.{DashboardAuthRateLimit, PublicBindGuard}

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
    previous = Application.get_env(:aiur, AiurWeb.Endpoint, [])

    Application.put_env(
      :aiur,
      AiurWeb.Endpoint,
      Keyword.merge(previous, public_bind: true, dashboard_auth_required: true, browser_basic_auth: false, allowed_hosts: ["www.example.com"])
    )

    on_exit(fn -> Application.put_env(:aiur, AiurWeb.Endpoint, previous) end)

    for route <- Phoenix.Router.routes(AiurWeb.Router) do
      path = Regex.replace(~r/[:*][^\/]+/, route.path, "fixture")
      conn = Plug.Test.conn(:get, path) |> Plug.Test.init_test_session(%{})
      response = AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))

      if response.status in 200..299 do
        assert PublicBindGuard.public_path?(%Plug.Conn{method: "GET", path_info: String.split(path, "/", trim: true)}),
               "unexpected unauthenticated success for #{route.path}"
      end
    end
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
