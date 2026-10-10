defmodule AiurWeb.DashboardPagesGateTest do
  use Aiur.TestSupport

  import Phoenix.ConnTest

  alias AiurWeb.Endpoint

  @endpoint Endpoint
  @not_found %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

  setup do
    previous = Application.fetch_env(:aiur, Endpoint)

    config =
      Keyword.merge(Application.get_env(:aiur, Endpoint, []),
        server: false,
        secret_key_base: String.duplicate("s", 64),
        dashboard_auth_required: true,
        dashboard_writable: false
      )

    Application.put_env(:aiur, Endpoint, config)
    Aiur.TestSupport.start_owned_endpoint!()
    previous_pages = Endpoint.config(:dashboard_pages)

    on_exit(fn ->
      Aiur.TestSupport.restore_app_env([{Endpoint, previous}])
      if Process.whereis(Endpoint), do: Phoenix.Config.put(Endpoint, :dashboard_pages, previous_pages)
    end)

    :ok
  end

  defp pages(value) do
    Phoenix.Config.put(Endpoint, :dashboard_pages, value)
    :ok
  end

  defp authed, do: Plug.Conn.put_req_header(build_conn(), "authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret"))

  describe "pages off" do
    setup do
      pages(false)
    end

    test "every page and asset path answers with the catch-all 404 JSON" do
      unknown = get(authed(), "/no-such-path")
      assert json_response(unknown, 404) == @not_found

      for path <- ["/", "/commands", "/decisions", "/build-order-documents/o/r/1/2", "/vendor/phoenix/phoenix.js", "/dashboard.css", "/aiur-logo.png"] do
        conn = get(authed(), path)
        assert conn.status == 404, path
        assert conn.resp_body == unknown.resp_body, path
        assert Plug.Conn.get_resp_header(conn, "content-type") == Plug.Conn.get_resp_header(unknown, "content-type"), path
      end
    end

    test "the JSON API still answers" do
      conn = get(authed(), "/api/v1/capabilities")

      assert %{"instance" => %{"run_shape" => _}} = json_response(conn, 200)
    end

    test "an unauthenticated page or asset probe gets the same 401 as an unknown path" do
      unknown = get(build_conn(), "/no-such-path")
      assert unknown.status == 401

      for path <- ["/commands", "/dashboard.css"] do
        conn = get(build_conn(), path)
        assert conn.status == 401, path
        assert Plug.Conn.get_resp_header(conn, "www-authenticate") == Plug.Conn.get_resp_header(unknown, "www-authenticate"), path
        assert conn.resp_body == unknown.resp_body, path
      end
    end

    test "a LiveView mount halts with a redirect" do
      assert {:halt, socket} = AiurWeb.DashboardPagesGate.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})
      assert socket.redirected == {:redirect, %{to: "/", status: 302}}
    end
  end

  describe "pages config absent" do
    setup do
      pages(nil)
    end

    test "pages and assets are served" do
      assert html_response(get(authed(), "/"), 200) =~ "<html"
      assert response(get(authed(), "/dashboard.css"), 200) =~ ":root {"
    end

    test "a LiveView mount continues" do
      socket = %Phoenix.LiveView.Socket{}
      assert AiurWeb.DashboardPagesGate.on_mount(:default, %{}, %{}, socket) == {:cont, socket}
    end
  end
end
