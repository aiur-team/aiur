defmodule AiurWeb.ModelsApiControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router
  @session_options Plug.Session.init(store: :cookie, key: "_aiur_test_key", signing_salt: "aiur-test-session")

  test "GET models returns configured dispatch order" do
    response = request(:get, "/api/v1/models")
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    body = Jason.decode!(response.resp_body)
    expected = AiurWeb.ModelsProjection.snapshot().routes
    assert Enum.map(body["routes"], & &1["backend"]) == Enum.map(expected, & &1.backend)
    assert Enum.map(body["routes"], & &1["position"]) == Enum.map(expected, & &1.position)
  end

  test "meter-less entries have null use, never a zero usage claim" do
    route = AiurWeb.ModelsProjection.route_for("codex:gpt-5.5:high", 0, ["codex:gpt-5.5:high"], %{}, %{"backends" => %{}}, DateTime.utc_now())
    assert route.usage.state == "unknown"
    assert Enum.all?(route.usage.windows, &is_nil(&1.used_percent))
  end

  defp request(method, path) do
    connection = method |> conn(path) |> Map.put(:secret_key_base, String.duplicate("s", 64)) |> AiurWeb.Session.call(@session_options) |> fetch_session()
    connection = put_private(connection, :aiur_dashboard_credentials, {"operator", "secret"})
    connection = put_req_header(connection, "authorization", Plug.BasicAuth.encode_basic_auth("operator", "secret"))
    Router.call(connection, Router.init([]))
  end
end
