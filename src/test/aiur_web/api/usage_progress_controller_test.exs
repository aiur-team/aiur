defmodule AiurWeb.Api.UsageProgressControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Aiur.TestSupport.EndpointStubs
  alias Aiur.TrackerIdentity
  alias AiurWeb.Router

  @identity %TrackerIdentity{
    version: 1,
    status: :joinable,
    kind: :github,
    owner: "owner",
    repository: "repo",
    provider_id: "I-5694",
    identifier: "5694",
    reason: nil
  }

  setup do
    Aiur.TestSupport.start_owned_endpoint!()

    EndpointStubs.put(
      usage_progress_activity_fun: fn -> %{entries: [entry()]} end,
      usage_progress_retention_fun: fn -> %{} end,
      usage_progress_history_fun: fn _identifier, _opts -> [row()] end
    )
  end

  test "an authenticated GET returns the versioned phase and progress read" do
    response = request(:get, "/api/v1/5694/progress")

    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["no-store"]
    body = Jason.decode!(response.resp_body)
    assert %{"contract" => "aiur.ticket_progress", "contract_version" => 1, "issue_identifier" => "5694"} = body
    assert body["phase"]["value"] == "review"
    assert %{"status" => "known", "percent" => 80} = body["progress"]
    assert [%{"type" => "progress", "summary" => "80%"}] = body["events"]
  end

  # The progress route sits after the generic `/api/v1/:issue_identifier` reads
  # would otherwise swallow it.
  test "the progress route is not shadowed by the generic issue routes" do
    assert %{plug: AiurWeb.Api.UsageProgressController} =
             Phoenix.Router.route_info(Router, "GET", "/api/v1/5694/progress", "localhost")
  end

  test "it uses the same Basic auth boundary as the other issue reads" do
    for path <- ["/api/v1/5694/progress", "/api/v1/state"],
        authorization <- [nil, Plug.BasicAuth.encode_basic_auth("operator", "wrong")] do
      assert request(:get, path, authorization).status == 401
    end
  end

  test "writes are refused with GET advertised" do
    for method <- [:post, :put, :patch, :delete] do
      response = request(method, "/api/v1/5694/progress")
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["GET"]
      assert %{"error" => %{"code" => "method_not_allowed"}} = Jason.decode!(response.resp_body)
    end
  end

  test "a bad limit or identifier is a 422 with a named error" do
    for limit <- ["0", "51", "ten", "5.5"] do
      response = request(:get, "/api/v1/5694/progress?limit=#{limit}")
      assert response.status == 422
      assert %{"error" => %{"code" => "invalid_limit"}} = Jason.decode!(response.resp_body)
    end

    response = request(:get, "/api/v1/%2E%2E/progress")
    assert response.status == 422
    assert %{"error" => %{"code" => "invalid_identifier"}} = Jason.decode!(response.resp_body)
  end

  defp request(method, path, authorization \\ Plug.BasicAuth.encode_basic_auth("operator", "secret")) do
    connection = conn(method, path) |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
    connection = if authorization, do: put_req_header(connection, "authorization", authorization), else: connection
    Router.call(connection, Router.init([]))
  end

  defp entry do
    %{
      identity: @identity,
      observed_at: ~U[2026-07-15 12:00:00Z],
      stage: %{status: :known, value: :review, observed_at: ~U[2026-07-15 11:59:00Z]},
      progress: %{status: :known, percent: 80, source: :phase, freshness: :fresh, observed_at: ~U[2026-07-15 12:00:00Z]}
    }
  end

  defp row,
    do: %{type: "event", id: 7, kind: "self", topic: "ticket.5694.agent.progress", label: "Progress", body: "80%", timestamp: "2026-07-15T12:00:00Z"}
end
