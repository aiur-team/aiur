defmodule AiurWeb.Api.SpendCapControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.Issue
  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TestSupport.GroupedScopes, as: GS

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, true)
    owner = self()
    identity = GS.identity(5693)
    payload = payload()

    EndpointStubs.put(
      ticket_spend_cap_opts: [
        repository_fun: fn -> {:ok, {identity.owner, identity.repository}} end,
        fetch_issue_states_fun: fn ["5693"] -> {:ok, [%Issue{id: "node-5693", identifier: "5693", title: "cap", state: "todo", tracker_identity: identity}]} end,
        store_get_fun: fn "5693" -> {:ok, payload} end,
        store_put_fun: fn ^identity, amount ->
          send(owner, {:put_cap, identity, amount})
          {:ok, payload}
        end,
        store_delete_fun: fn "5693" ->
          send(owner, :delete_cap)
          :ok
        end
      ]
    )

    :ok
  end

  test "GET returns the versioned ticket-scoped cap contract" do
    response = request(:get, "/api/v1/5693/spend-cap")

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    body = Jason.decode!(response.resp_body)
    assert body["contract"] == "aiur.ticket_spend_cap"
    assert body["contract_version"] == 1
    assert body["job_id"] == "5693"
    assert body["ticket"] == %{"owner" => "its-everdred", "repository" => "aiur", "identifier" => "5693"}
  end

  test "PUT resolves the configured repository identity and sets an exact USD cap" do
    response = request(:put, "/api/v1/5693/spend-cap", %{"amount" => "1.25", "currency" => "USD"})

    assert response.status == 200
    assert_receive {:put_cap, %Aiur.TrackerIdentity{identifier: "5693"}, "1.25"}, 1_000
  end

  test "DELETE clears the cap without reopening a terminal ticket" do
    response = request(:delete, "/api/v1/5693/spend-cap")
    assert response.status == 204
    assert_receive :delete_cap, 1_000
  end

  test "invalid money is rejected before a tracker or store call" do
    for amount <- [1.25, "0", "-1", "1.1234567", "1e3", "01.2"] do
      response = request(:put, "/api/v1/5693/spend-cap", %{"amount" => amount})
      assert response.status == 422
      assert Jason.decode!(response.resp_body)["error"]["code"] == "invalid_amount"
    end

    refute_received {:put_cap, _, _}
  end

  test "unsupported currency is rejected with a stable error code" do
    response = request(:put, "/api/v1/5693/spend-cap", %{"amount" => "1.25", "currency" => "EUR"})

    assert response.status == 422
    assert Jason.decode!(response.resp_body)["error"]["code"] == "unsupported_currency"
    refute_received {:put_cap, _, _}
  end

  test "writes require same-origin protection and a writable dashboard" do
    response = request(:put, "/api/v1/5693/spend-cap", %{"amount" => "1.25"}, write_headers?: false)
    assert response.status == 403

    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    response = request(:delete, "/api/v1/5693/spend-cap")
    assert response.status == 403
    refute_received :delete_cap
  end

  test "reads and writes require dashboard authentication" do
    for {method, body} <- [{:get, nil}, {:put, %{"amount" => "1.25"}}, {:delete, nil}] do
      response = request(method, "/api/v1/5693/spend-cap", body, auth?: false)
      assert response.status == 401
    end
  end

  defp request(method, path, body \\ nil, opts \\ []) do
    encoded = if body, do: Jason.encode!(body), else: ""

    conn =
      method
      |> conn(path, encoded)
      |> put_req_header("content-type", "application/json")

    conn =
      if Keyword.get(opts, :write_headers?, method in [:put, :delete]) do
        conn
        |> put_req_header("origin", "http://127.0.0.1")
        |> put_req_header("x-aiur-request", "1")
      else
        conn
      end

    conn =
      if Keyword.get(opts, :auth?, true),
        do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("operator:test-dashboard-secret")),
        else: conn

    AiurWeb.Endpoint.call(conn, AiurWeb.Endpoint.init([]))
  end

  defp payload do
    %{
      "contract" => "aiur.ticket_spend_cap",
      "contract_version" => 1,
      "schema_version" => 1,
      "job_id" => "5693",
      "ticket" => %{"owner" => "its-everdred", "repository" => "aiur", "identifier" => "5693"},
      "currency" => "USD",
      "cap_amount" => "1.25",
      "spent_amount" => "0.50",
      "remaining_amount" => "0.75",
      "state" => "active",
      "end_state" => nil,
      "coverage" => %{"status" => "known", "known" => 1, "unknown" => 0, "reasons" => []},
      "authority" => %{},
      "configured_at" => "2026-10-24T20:00:00Z",
      "reached_at" => nil,
      "effects" => %{"stop" => "not_applicable", "event" => "not_applicable", "tracker_transition" => "not_applicable"}
    }
  end
end
