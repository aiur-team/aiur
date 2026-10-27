defmodule Aiur.ControlControllerTestProbe do
  @moduledoc false

  def read_wait(parent_name), do: wait_for_test_release(parent_name)
  def write_wait(parent_name), do: wait_for_test_release(parent_name)

  defp wait_for_test_release(parent_name) do
    parent = Process.whereis(parent_name)
    send(parent, {:control_controller_probe_started, self()})

    receive do
      :finish -> send(parent, {:control_controller_probe_finished, self()})
    end
  end
end

defmodule AiurWeb.ControlControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AiurWeb.Router

  @session_options Plug.Session.init(store: :cookie, key: "_aiur_control_test", signing_salt: "aiur-test-session")
  @contract %{"contract" => "aiur.control.call", "contract_version" => 1}
  @read_parent :control_api_read_timeout
  @write_parent :control_api_write_timeout

  setup do
    Aiur.TestSupport.start_owned_endpoint!()
    root = Path.join(System.tmp_dir!(), "control-api-#{System.unique_integer([:positive])}")
    token_path = Path.join(root, "tokens.json")
    audit_path = Path.join(root, "control-audit.ndjson")
    previous_token_path = Application.get_env(:aiur, :client_tokens_path)
    previous_audit_path = Application.get_env(:aiur, :control_audit_file)
    previous_cap = Aiur.Orchestrator.max_concurrent_agents()
    Application.put_env(:aiur, :client_tokens_path, token_path)
    Application.put_env(:aiur, :control_audit_file, audit_path)
    assert {:ok, read_token} = Aiur.ClientTokens.create("control-read", "read")
    assert {:ok, write_token} = Aiur.ClientTokens.create("control-write", "write")

    on_exit(fn ->
      restore_env(:client_tokens_path, previous_token_path)
      restore_env(:control_audit_file, previous_audit_path)
      if is_map(previous_cap), do: Aiur.AgentControlCLI.set_max_agents(previous_cap.max)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    %{read_token: read_token, write_token: write_token, audit_path: audit_path, previous_cap: previous_cap}
  end

  test "read token runs allowlisted calls and returns the local exit marker", %{read_token: token} do
    response = post_control(token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.status()"}))

    assert response.status == 200

    assert %{
             "contract" => "aiur.control.result",
             "contract_version" => 1,
             "build" => %{"version" => version, "commit" => commit},
             "output" => output
           } = Jason.decode!(response.resp_body)

    assert is_binary(version)
    assert is_binary(commit)
    assert output =~ ~r/__AIUR_CONTROL_EXIT__:[01]\n$/

    successful = post_control(token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.executor_subscriptions()"}))
    assert String.ends_with?(Jason.decode!(successful.resp_body)["output"], "__AIUR_CONTROL_EXIT__:0\n")
  end

  test "endpoint parses a valid control request body for a read token", %{read_token: token} do
    response =
      conn(:post, "/api/v1/control", Jason.encode!(Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.executor_subscriptions()"})))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> then(&AiurWeb.Endpoint.call(&1, AiurWeb.Endpoint.init([])))

    assert response.status == 200
    assert String.ends_with?(Jason.decode!(response.resp_body)["output"], "__AIUR_CONTROL_EXIT__:0\n")
  end

  test "read token cannot run a write call and the refusal is audited", %{read_token: token, audit_path: path, previous_cap: previous_cap} do
    response = post_control(token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.set_max_agents(3)"}))

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["error"]["code"] == "scope_denied"
    assert Aiur.Orchestrator.max_concurrent_agents() == previous_cap
    assert [record] = audit_records(path)
    assert record["outcome"] == "refused"
    assert record["call"] == "Aiur.AgentControlCLI.set_max_agents/1"
  end

  test "read-only dashboard still permits reads and refuses and audits write calls", %{read_token: read_token, write_token: write_token, audit_path: path, previous_cap: previous_cap} do
    previous_writable = AiurWeb.Endpoint.config(:dashboard_writable)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)

    try do
      read_response = post_control(read_token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.status()"}))
      assert read_response.status == 200

      write_response = post_control(write_token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.set_max_agents(3)"}))
      assert write_response.status == 403
      assert Jason.decode!(write_response.resp_body)["error"]["reason"] == "dashboard_read_only"
      assert Aiur.Orchestrator.max_concurrent_agents() == previous_cap
      assert [record] = audit_records(path)
      assert record["scope"] == "write"
      assert record["outcome"] == "refused"
      assert record["call"] == "Aiur.AgentControlCLI.set_max_agents/1"
    after
      Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous_writable)
    end
  end

  test "write token executes and audits a write call", %{write_token: token, audit_path: path, previous_cap: previous_cap} do
    response = post_control(token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.set_max_agents(3)"}))

    assert response.status == 200
    output = Jason.decode!(response.resp_body)["output"]
    assert output =~ "aiur: max-agents set to 3"
    assert String.ends_with?(output, "__AIUR_CONTROL_EXIT__:0\n")
    assert %{max: 3} = Aiur.Orchestrator.max_concurrent_agents()
    assert [record] = audit_records(path)
    assert record["token"] == "control-write"
    assert record["scope"] == "write"
    assert record["outcome"] == "ok"
    assert record["call"] == "Aiur.AgentControlCLI.set_max_agents/1"
    assert record["expression_sha256"] == :crypto.hash(:sha256, "Aiur.AgentControlCLI.set_max_agents(3)") |> Base.encode16(case: :lower)
    Aiur.AgentControlCLI.set_max_agents(previous_cap.max)
  end

  test "basic auth is not accepted and a revoked bearer receives 401", %{read_token: token, audit_path: path} do
    basic = request(:post, "Basic " <> Base.encode64("operator:secret"), @contract)
    assert basic.status == 401

    assert :ok = Aiur.ClientTokens.revoke("control-read")
    revoked = post_control(token, Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.status()"}))
    assert revoked.status == 401
    assert Enum.all?(audit_records(path), &(&1["outcome"] == "refused"))
  end

  test "invalid expressions are refused with the build and audited", %{read_token: token, audit_path: path} do
    cases = [
      {"System.cmd(\"id\", [])", "not_allowlisted"},
      {"Aiur.AgentControlCLI.message(\"1\", File.read!(\"/etc/passwd\"))", "non_literal_argument"},
      {"Aiur.AgentControlCLI.status(nested: fn -> :ok end)", "option_not_allowed"},
      {~s|Aiur.AgentControlCLI.operator_answer(decision_id: "d", operator: true, option_id: "o", expected_version: 1, confirmation: "d")|, "denied_remote"}
    ]

    for {expression, reason} <- cases do
      response = post_control(token, Map.merge(@contract, %{"expression" => expression}))
      assert response.status == 422, expression
      assert Jason.decode!(response.resp_body)["error"]["reason"] == reason
    end

    assert Enum.map(audit_records(path), & &1["outcome"]) == List.duplicate("refused", length(cases))
  end

  test "max_scope read refuses a write call even with a write token", %{write_token: token, audit_path: path, previous_cap: previous_cap} do
    request_body = Map.merge(@contract, %{"expression" => "Aiur.AgentControlCLI.set_max_agents(3)", "max_scope" => "read"})
    response = post_control(token, request_body)

    assert response.status == 403
    assert Jason.decode!(response.resp_body)["error"]["code"] == "scope_denied"
    assert Aiur.Orchestrator.max_concurrent_agents() == previous_cap
    assert [record] = audit_records(path)
    assert record["outcome"] == "refused"
  end

  test "read timeout kills its task and write timeout is audited as unknown", %{read_token: read_token, write_token: write_token, audit_path: path} do
    read_parent = @read_parent
    Process.register(self(), read_parent)
    read_payload = Map.merge(@contract, %{"expression" => "Aiur.ControlControllerTestProbe.read_wait(#{inspect(read_parent)})", "timeout_ms" => 1_000})
    read_response = post_control(read_token, read_payload)

    assert read_response.status == 504, read_response.resp_body
    assert {:control_controller_probe_started, read_pid} = receive_probe_started()
    refute Process.alive?(read_pid)
    Process.unregister(read_parent)

    write_parent = @write_parent
    Process.register(self(), write_parent)
    write_payload = Map.merge(@contract, %{"expression" => "Aiur.ControlControllerTestProbe.write_wait(#{inspect(write_parent)})", "timeout_ms" => 1_000})
    write_response = post_control(write_token, write_payload)

    assert write_response.status == 504
    assert {:control_controller_probe_started, write_pid} = receive_probe_started()
    assert Process.alive?(write_pid)
    monitor = Process.monitor(write_pid)
    send(write_pid, :finish)
    assert_receive {:control_controller_probe_finished, ^write_pid}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^write_pid, _reason}, 1_000
    assert Enum.any?(audit_records(path), &(&1["outcome"] == "timeout_unknown"))
    Process.unregister(write_parent)
  end

  test "oversized unauthenticated endpoint body is rejected before JSON decoding" do
    conn =
      conn(:post, "/api/v1/control", String.duplicate("x", 1_000_000))
      |> put_req_header("content-length", "1000000")
      |> put_req_header("content-type", "application/json")
      |> then(&AiurWeb.Endpoint.call(&1, AiurWeb.Endpoint.init([])))

    assert conn.status in [401, 413]
    refute conn.status == 422
    assert match?(%Plug.Conn.Unfetched{aspect: :body_params}, conn.body_params)
  end

  test "control route method catch does not shadow issue routes", %{read_token: token} do
    method = request(:get, "Bearer " <> token, %{}, "/api/v1/control")
    issue_route = Phoenix.Router.route_info(Router, "POST", "/api/v1/12345", "localhost")

    assert method.status == 405
    assert issue_route.plug == AiurWeb.ObservabilityApiController
  end

  defp post_control(token, payload), do: request(:post, "Bearer " <> token, payload)

  defp request(method, authorization, payload, path \\ "/api/v1/control") do
    conn =
      method
      |> conn(path, Jason.encode!(payload))
      |> Map.put(:secret_key_base, String.duplicate("s", 64))
      |> AiurWeb.Session.call(@session_options)
      |> fetch_session()
      |> put_req_header("content-type", "application/json")
      |> put_private(:aiur_dashboard_credentials, {"operator", "secret"})
      |> Plug.Parsers.call(Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Jason))

    conn = if authorization, do: put_req_header(conn, "authorization", authorization), else: conn
    response = Router.call(conn, Router.init([]))

    receive do
      {:plug_conn, :sent} -> :ok
    after
      0 -> :ok
    end

    response
  end

  defp audit_records(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp restore_env(key, nil), do: Application.delete_env(:aiur, key)
  defp restore_env(key, value), do: Application.put_env(:aiur, key, value)

  defp receive_probe_started do
    receive do
      {:control_controller_probe_started, _pid} = message -> message
      _other -> receive_probe_started()
    after
      1_000 -> flunk("expected control-call probe to start")
    end
  end
end
