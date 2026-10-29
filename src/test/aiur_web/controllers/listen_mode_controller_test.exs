defmodule AiurWeb.ListenModeControllerTest do
  use Aiur.TestSupport
  import Plug.Conn
  import Plug.Test
  alias Aiur.{Listener, Orchestrator}
  alias Aiur.Orchestrator.{ListenerModes, State}
  alias Aiur.TestSupport.EndpointStubs
  alias AiurWeb.Router

  defmodule Server do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state, name: Aiur.Orchestrator)
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:listener_get_mode, id}, _from, state), do: ListenerModes.get_mode(state, id)
    def handle_call({:listener_set_mode, id, mode, opts}, _from, state), do: ListenerModes.set_mode(state, id, mode, opts)
    def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported}, state}

    @impl true
    def handle_info(_message, state), do: {:noreply, state}
  end

  setup do
    original = Process.whereis(Orchestrator)
    if original, do: Process.unregister(Orchestrator)
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Orchestrator) end)
    dir = Aiur.TestSupport.tmp_root!("listen-mode-cli")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(dir) end)
    Aiur.TestSupport.put_runtime_state_dir!(dir)
    start_supervised!({Server, %State{last_polled_issues: %{"42" => %{identifier: "42"}}}})
    :ok
  end

  test "stale expected_version returns 409 with current record" do
    assert request(:post, %{mode: "steer", expected_version: 0}).status == 200
    response = request(:post, %{mode: "async", expected_version: 0})
    assert response.status == 409, response.resp_body
    assert %{"error" => "mode_conflict", "current" => %{"requested" => "steer", "version" => 1}} = Jason.decode!(response.resp_body)
    assert {:ok, %{requested: :steer, version: 1}} = Listener.get_mode("42")
  end

  test "same idempotency key returns first result and GET reads it" do
    body = %{mode: "async", expected_version: 0, idempotency_key: "retry", actor: "executor"}
    first = request(:post, body)
    assert first.status == 200
    assert request(:post, body).resp_body == first.resp_body
    assert request(:get, %{}).resp_body == first.resp_body
    assert %{"requested" => "async", "effective" => nil, "effective_reason" => "not_running", "version" => 1, "actor" => "executor", "routing" => "legacy"} = Jason.decode!(first.resp_body)
  end

  test "mute is accepted and round-trips through the HTTP mode control" do
    response = request(:post, %{mode: "mute", expected_version: 0})
    assert response.status == 200
    assert %{"requested" => "mute", "effective" => "mute", "version" => 1} = Jason.decode!(response.resp_body)
    assert request(:get, %{}).resp_body == response.resp_body
  end

  test "invalid mode and metadata return 422 without writing" do
    for body <- [%{mode: "bad", expected_version: 0}, %{mode: "sync"}, %{mode: "sync", expected_version: 0, actor: "system"}, %{mode: "sync", expected_version: 0, idempotency_key: 42}] do
      assert request(:post, body).status == 422
    end

    assert {:ok, %{version: 0}} = Listener.get_mode("42")
  end

  test "unknown tickets return 404 for reads and writes" do
    for method <- [:get, :post] do
      assert request(method, %{mode: "sync", expected_version: 0}, ticket: "unknown").status == 404
    end
  end

  test "read-only dashboard refuses writes but allows reads" do
    assert request(:post, %{mode: "async", expected_version: 0}, writable: false).status == 403
    assert {:ok, %{version: 0}} = Listener.get_mode("42")
    assert request(:get, %{}, writable: false).status == 200
  end

  test "authentication, origin and custom header protect writes" do
    body = %{mode: "async", expected_version: 0}
    assert request(:post, body, authorization: false).status == 401
    assert request(:post, body, origin: "https://evil.example").status == 403
    assert request(:post, body, header: false).status == 403
    assert {:ok, %{version: 0}} = Listener.get_mode("42")
  end

  test "unsupported methods return 405" do
    response = request(:delete, %{})
    assert response.status == 405
    assert get_resp_header(response, "allow") == ["GET, POST"]
  end

  defp request(method, body, opts \\ []) do
    EndpointStubs.put(dashboard_writable: Keyword.get(opts, :writable, true))
    session = Plug.Session.init(store: :cookie, key: "_aiur_test_key", signing_salt: "aiur-test-session")

    connection =
      conn(method, "/api/v1/#{Keyword.get(opts, :ticket, "42")}/listen-mode", body)
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
      |> AiurWeb.Session.call(session)
      |> fetch_session()
      |> put_req_header("origin", Keyword.get(opts, :origin, "http://127.0.0.1"))

    connection = if Keyword.get(opts, :authorization, true), do: put_req_header(connection, "authorization", Plug.BasicAuth.encode_basic_auth("operator", "secret")), else: connection
    connection = if Keyword.get(opts, :header, true), do: put_req_header(connection, "x-aiur-request", "1"), else: connection
    Router.call(connection, Router.init([]))
  end
end
