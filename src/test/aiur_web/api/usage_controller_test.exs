defmodule AiurWeb.Api.UsageControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TestSupport.GroupedScopes, as: GS
  alias AiurWeb.Router

  setup do
    Aiur.TestSupport.start_owned_endpoint!()

    records = [
      GS.claude_record(1, ticket: GS.identity(5692), run_id: "run-a", tokens: %{input: 100}),
      GS.claude_record(2, ticket: GS.identity(77), run_id: "run-a", tokens: %{input: 9_999})
    ]

    EndpointStubs.put(
      ticket_usage_opts: [
        scan_fun: fn options -> {:ok, Enum.filter(records, &(&1.position > Keyword.fetch!(options, :after)))} end,
        cells_snapshot_fun: fn -> GS.source(records) end,
        repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end
      ]
    )

    :ok
  end

  test "returns the asked ticket's usage without being shadowed by the generic issue route" do
    response = request(:get, "/api/v1/5692/usage")

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    body = Jason.decode!(response.resp_body)
    assert body["schema_version"] == 1
    assert body["ticket"]["identifier"] == "5692"
    assert body["totals"]["tokens"] == %{"input" => 100}
  end

  test "an unknown ticket answers the documented not-found shape" do
    response = request(:get, "/api/v1/4242/usage")

    assert response.status == 404
    assert Jason.decode!(response.resp_body) == %{"error" => %{"code" => "usage_not_found", "message" => "No usage recorded for issue"}}
  end

  test "a miss behind a retired ledger prefix answers a distinct not-found code" do
    retained = [GS.claude_record(5, ticket: GS.identity(77), tokens: %{input: 1})]

    EndpointStubs.put(
      ticket_usage_opts: [
        scan_fun: fn _options -> {:ok, retained} end,
        cells_snapshot_fun: fn -> GS.source(retained) end,
        repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end
      ]
    )

    response = request(:get, "/api/v1/5692/usage")
    assert response.status == 404
    assert Jason.decode!(response.resp_body)["error"]["code"] == "usage_unresolvable"
  end

  test "a non-numeric identifier is rejected as invalid" do
    response = request(:get, "/api/v1/MT-1/usage")

    assert response.status == 422
    assert Jason.decode!(response.resp_body)["error"]["code"] == "invalid_identifier"
  end

  test "an unreadable ledger answers 503 instead of an empty report" do
    EndpointStubs.put(
      ticket_usage_opts: [
        scan_fun: fn _options -> {:error, :corrupt} end,
        cells_snapshot_fun: fn -> GS.source([]) end,
        repository_fun: fn -> {:ok, {"its-everdred", "aiur"}} end
      ]
    )

    response = request(:get, "/api/v1/5692/usage")

    assert response.status == 503
    assert Jason.decode!(response.resp_body)["error"]["code"] == "usage_unavailable"
  end

  test "non-GET methods return 405 with GET allowed" do
    for method <- [:post, :put, :patch, :delete] do
      response = request(method, "/api/v1/5692/usage")
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
    end
  end

  # Usage carries cost, so it must sit behind the same Basic Auth as /api/v1/state.
  test "dashboard credentials are required and wrong credentials fail" do
    for authorization <- [nil, Plug.BasicAuth.encode_basic_auth("operator", "wrong")] do
      response = request(:get, "/api/v1/5692/usage", authorization)
      assert response.status == 401
      refute response.resp_body =~ "totals"
    end
  end

  test "unconfigured auth fails closed with the same boundary as state" do
    for path <- ["/api/v1/5692/usage", "/api/v1/state"] do
      response = conn(:get, path) |> put_private(:aiur_dashboard_credentials, nil) |> Router.call(Router.init([]))
      # The test endpoint enforces auth, so an unconfigured credential challenges.
      assert response.status == 401
      assert response.halted
    end
  end

  defp request(method, path, authorization \\ Plug.BasicAuth.encode_basic_auth("operator", "secret")) do
    connection = conn(method, path) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    connection = if authorization, do: put_req_header(connection, "authorization", authorization), else: connection
    Router.call(connection, Router.init([]))
  end
end
