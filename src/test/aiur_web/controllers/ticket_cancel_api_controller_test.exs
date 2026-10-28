defmodule AiurWeb.TicketCancelApiControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Router

  @path "/api/v1/NUC-42/cancel"
  @session_options Plug.Session.init(
                     store: :cookie,
                     key: "_aiur_test_key",
                     signing_salt: "aiur-test-session"
                   )

  defmodule CancelOrchestrator do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:cancel_agent, identifier}, _from, state) do
      send(Keyword.fetch!(state, :owner), {:cancelled, identifier})
      {:reply, Keyword.fetch!(state, :result), state}
    end
  end

  test "returns 200 only after the named process exit is observed" do
    orchestrator = start_cancel_orchestrator({:ok, cancel_result("exited", "killed")})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

    assert response = request(:post)
    assert response.status == 200

    assert %{
             "contract" => "aiur.ticket_cancel",
             "contract_version" => 1,
             "issue_identifier" => "NUC-42",
             "tracker_state" => "cancelled",
             "process" => %{
               "handle" => "NUC-42:attempt-1",
               "status" => "exited",
               "exit_status" => "killed",
               "exited_at" => "2026-10-24T18:30:00Z",
               "observed_at" => "2026-10-24T18:30:00Z"
             }
           } = Jason.decode!(response.resp_body)

    assert_received {:cancelled, "NUC-42"}
  end

  test "a process that did not exit returns the versioned result with 409" do
    orchestrator = start_cancel_orchestrator({:ok, cancel_result("still_running", nil)})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

    response = request(:post)

    assert response.status == 409

    assert %{"contract" => "aiur.ticket_cancel", "process" => %{"status" => "still_running", "exit_status" => nil}} =
             Jason.decode!(response.resp_body)
  end

  test "a known ticket without a running agent returns 409" do
    orchestrator = start_cancel_orchestrator({:error, :no_running_agent})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

    response = request(:post)

    assert response.status == 409

    assert Jason.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "agent_not_running",
               "message" => "Agent is not currently running"
             }
           }
  end

  test "an unknown ticket returns 404" do
    orchestrator = start_cancel_orchestrator({:error, :issue_not_found})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

    response = request(:post)

    assert response.status == 404

    assert Jason.decode!(response.resp_body) == %{
             "error" => %{
               "code" => "issue_not_found",
               "message" => "Issue not found"
             }
           }
  end

  test "the cancellation route requires dashboard authentication" do
    orchestrator = start_cancel_orchestrator({:ok, cancel_result("exited", "killed")})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

    response = request(:post, authorization: nil)

    assert response.status == 401
    refute_received {:cancelled, "NUC-42"}

    authenticated = request(:post)
    assert authenticated.status == 200
    assert_received {:cancelled, "NUC-42"}
  end

  test "the cancellation route is forbidden in read-only mode" do
    orchestrator = start_cancel_orchestrator({:ok, cancel_result("exited", "killed")})
    EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: false)

    response = request(:post)

    assert response.status == 403
    assert Jason.decode!(response.resp_body) == %{"error" => "dashboard is read-only"}
    refute_received {:cancelled, "NUC-42"}
  end

  test "operational failures return standard 503 errors without process evidence" do
    cases = [
      {{:error, :timeout}, "orchestrator_unavailable"},
      {{:error, :unavailable}, "orchestrator_unavailable"},
      {{:error, {:tracker_cancel_failed, :write_failed}}, "cancel_failed"}
    ]

    for {result, code} <- cases do
      orchestrator = start_cancel_orchestrator(result)
      EndpointStubs.put(orchestrator: orchestrator, dashboard_writable: true)

      response = request(:post)
      body = Jason.decode!(response.resp_body)

      assert response.status == 503
      assert %{"error" => %{"code" => ^code, "message" => message}} = body
      assert is_binary(message)
      refute Map.has_key?(body, "process")

      stop_supervised!(CancelOrchestrator)
    end
  end

  test "other methods are rejected before the generic ticket route" do
    EndpointStubs.put(dashboard_writable: true)

    for method <- [:get, :put, :patch, :delete] do
      response = request(method)
      assert response.status == 405
    end
  end

  defp start_cancel_orchestrator(result) do
    start_supervised!({CancelOrchestrator, owner: self(), result: result})
  end

  defp request(method, opts \\ []) do
    authorization =
      Keyword.get(
        opts,
        :authorization,
        Plug.BasicAuth.encode_basic_auth("operator", "secret")
      )

    connection =
      method
      |> conn(@path)
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
      |> AiurWeb.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("origin", "http://127.0.0.1")
      |> put_req_header("x-aiur-request", "1")

    connection =
      if authorization,
        do: put_req_header(connection, "authorization", authorization),
        else: connection

    Router.call(connection, Router.init([]))
  end

  defp cancel_result(status, exit_status) do
    exited_at = if status == "exited", do: "2026-10-24T18:30:00Z", else: nil

    %{
      contract: "aiur.ticket_cancel",
      contract_version: 1,
      issue_identifier: "NUC-42",
      tracker_state: "cancelled",
      process: %{
        handle: "NUC-42:attempt-1",
        status: status,
        exit_status: exit_status,
        exited_at: exited_at,
        observed_at: "2026-10-24T18:30:00Z"
      }
    }
  end
end
