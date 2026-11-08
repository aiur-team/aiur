Code.require_file("../aiur/conversation/journal_support.exs", __DIR__)

defmodule AiurWeb.ExecutorHookControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias Aiur.Conversation.TestSupport
  alias Aiur.Executor.{HookToken, Session, SessionIngest}
  alias AiurWeb.Router

  setup context do
    context = TestSupport.setup(context)
    previous = Application.fetch_env(:aiur, :executor_state_dir)
    key = System.get_env("AIUR_INSTANCE_KEY")
    Application.put_env(:aiur, :executor_state_dir, Path.join(context.root, "executor"))
    System.put_env("AIUR_INSTANCE_KEY", "hook-http")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:aiur, :executor_state_dir, value)
        :error -> Application.delete_env(:aiur, :executor_state_dir)
      end

      if key, do: System.put_env("AIUR_INSTANCE_KEY", key), else: System.delete_env("AIUR_INSTANCE_KEY")
    end)

    start_supervised!({Session, instance_key: "hook-http"})
    ingest = start_supervised!({SessionIngest, pubsub: context.pubsub})
    assert :ok = HookToken.ensure()
    assert {:ok, token} = HookToken.read()
    Map.merge(context, %{token: token, ingest: ingest})
  end

  test "unconfigured credential returns 401 and leaves binding unchanged", %{token: token} do
    assert {:ok, pending} = Session.attach(%{harness: "claude"})
    File.rm!(HookToken.path())
    response = request(token)
    assert response.status == 401
    assert Jason.decode!(response.resp_body) == %{"error" => %{"code" => "executor_hook_unconfigured"}}
    assert {:ok, ^pending} = Session.current()
  end

  test "missing, wrong, duplicate bearer and nonloopback callers are unauthorized", %{token: token} do
    for presented <- [nil, "wrong"] do
      response = request(presented)
      assert response.status == 401
      assert Jason.decode!(response.resp_body) == %{"error" => %{"code" => "executor_hook_unauthorized"}}
    end

    response = request(token, remote_ip: {192, 0, 2, 1})
    assert response.status == 401
    response = build_conn(token) |> prepend_req_headers([{"authorization", "Bearer #{token}"}]) |> route()
    assert response.status == 401
    assert Session.current() == :none
  end

  test "loopback IPv4 and IPv6 hooks bind asynchronously and return 202", %{token: token} do
    assert {:ok, pending} = Session.attach(%{harness: "claude"})

    for ip <- [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      response = request(token, remote_ip: ip)
      assert response.status == 202
      assert Jason.decode!(response.resp_body) == %{"ok" => true}
    end

    SessionIngest.rejected_counts()
    assert {:ok, bound} = Session.current()
    assert bound.binding_id == pending.binding_id
    assert bound.provider_session_id == "session-http"
  end

  test "accepts in read-only dashboard mode without waiting for the ingest worker", %{token: token, ingest: ingest} do
    Aiur.TestSupport.start_owned_endpoint!()
    previous = AiurWeb.Endpoint.config(:dashboard_writable)
    Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, false)
    :sys.suspend(ingest)

    try do
      response = Task.async(fn -> request(token) end) |> Task.await(1000)
      assert response.status == 202
    after
      :sys.resume(ingest)
      Phoenix.Config.put(AiurWeb.Endpoint, :dashboard_writable, previous)
    end
  end

  test "harness comes only from query and malformed hooks still receive 202", %{token: token} do
    assert {:ok, pending} = Session.attach(%{harness: "claude"})
    response = build_conn(token, "/api/v1/executor/hook", Map.put(payload(), "harness", "claude")) |> route()
    assert response.status == 202
    assert SessionIngest.rejected_counts()[:invalid_payload] == 1
    assert {:ok, ^pending} = Session.current()
    response = build_conn(token, "/api/v1/executor/hook?harness=claude", %{}) |> route()
    assert response.status == 202
    assert SessionIngest.rejected_counts()[:invalid_payload] == 2
  end

  test "forwards hook command parent pid when the Claude payload has no pid", %{token: token} do
    assert {:ok, _} = Session.attach(%{harness: "claude"})
    body = Map.delete(payload(), "pid")
    response = build_conn(token, "/api/v1/executor/hook?harness=claude", body) |> put_req_header("x-aiur-executor-pid", "456") |> route()
    assert response.status == 202
    SessionIngest.rejected_counts()
    assert {:ok, binding} = Session.current()
    assert binding.pid == "456"
  end

  test "authenticated unsupported methods return 405", %{token: token} do
    response = :get |> conn("/api/v1/executor/hook") |> put_req_header("authorization", "Bearer #{token}") |> route()
    assert response.status == 405
    assert get_resp_header(response, "allow") == ["POST"]
  end

  defp request(token, opts \\ []) do
    connection = build_conn(token)
    connection = if ip = opts[:remote_ip], do: %{connection | remote_ip: ip}, else: connection
    route(connection)
  end

  defp build_conn(token, path \\ "/api/v1/executor/hook?harness=claude", body \\ payload()) do
    connection = conn(:post, path, body)
    if token, do: put_req_header(connection, "authorization", "Bearer #{token}"), else: connection
  end

  defp route(connection), do: Router.call(connection, Router.init([]))
  defp payload, do: %{"hook_event_name" => "SessionStart", "session_id" => "session-http", "source" => "startup", "pid" => "123"}
end
