defmodule AiurWeb.UnitsRedirectTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias AiurWeb.{Router, UnitsRedirectController}

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    :ok
  end

  test "GET /units redirects permanently home behind dashboard authentication" do
    conn =
      :get
      |> dashboard_conn("/units")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["/"]
  end

  test "the permanent redirect preserves the raw query and omits an empty question mark" do
    for {path, expected} <- [{"/units?v=1&scope=all", "/?v=1&scope=all"}, {"/units", "/"}] do
      redirected = UnitsRedirectController.legacy(conn(:get, path), %{})
      assert redirected.status == 301
      assert get_resp_header(redirected, "location") == [expected]
    end
  end

  test "an unauthenticated Units URL does not redirect" do
    conn = Router.call(dashboard_conn(:get, "/units"), Router.init([]))
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Aiur\""]
    assert get_resp_header(conn, "location") == []
  end

  defp dashboard_conn(method, path) do
    method
    |> conn(path)
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    |> AiurWeb.Session.call(Plug.Session.init(store: :cookie, key: "_aiur_test_key", signing_salt: "aiur-test-session"))
    |> fetch_session()
  end
end
