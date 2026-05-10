defmodule SymphonyElixirWeb.RouterAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixirWeb.Router

  setup do
    original_username = System.get_env("SYMPHONY_DASHBOARD_USERNAME")
    original_password = System.get_env("SYMPHONY_DASHBOARD_PASSWORD")

    on_exit(fn ->
      restore_env("SYMPHONY_DASHBOARD_USERNAME", original_username)
      restore_env("SYMPHONY_DASHBOARD_PASSWORD", original_password)
    end)

    :ok
  end

  test "allows dashboard requests when credentials are not configured" do
    System.delete_env("SYMPHONY_DASHBOARD_USERNAME")
    System.delete_env("SYMPHONY_DASHBOARD_PASSWORD")

    conn = Router.call(conn(:get, "/missing"), Router.init([]))

    assert conn.status == 404
  end

  test "requires basic auth when credentials are configured" do
    System.put_env("SYMPHONY_DASHBOARD_USERNAME", "operator")
    System.put_env("SYMPHONY_DASHBOARD_PASSWORD", "secret")

    conn = Router.call(conn(:get, "/api/v1/state"), Router.init([]))

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Basic realm=\"Symphony\""]
  end

  test "accepts matching basic auth credentials" do
    System.put_env("SYMPHONY_DASHBOARD_USERNAME", "operator")
    System.put_env("SYMPHONY_DASHBOARD_PASSWORD", "secret")

    conn =
      :get
      |> conn("/missing")
      |> put_req_header("authorization", "Basic " <> Base.encode64("operator:secret"))
      |> Router.call(Router.init([]))

    assert conn.status == 404
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
