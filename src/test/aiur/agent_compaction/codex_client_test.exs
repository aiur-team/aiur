defmodule Aiur.AgentCompaction.CodexClientTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentCompaction.CodexClient
  alias Aiur.AppServer.Rpc, as: AppServerRpc

  test "builds the verified app-server request shape" do
    assert {:ok, frame} = CodexClient.build_request("thread-123", 12)
    assert frame["method"] == "thread/compact/start"
    assert frame["params"] == %{"threadId" => "thread-123"}
    assert frame["id"] == 12
    refute Map.has_key?(frame["params"], "summaryPrompt")
  end

  test "rejects an absent thread id before sending anything" do
    assert {:error, :invalid_thread_id} = CodexClient.build_request("")
    assert {:error, :invalid_thread_id} = CodexClient.build_request(nil)
  end

  test "rejects an invalid port and thread identity" do
    assert {:error, {:invalid_thread_or_port, "thread-1"}} = CodexClient.request_compact(self(), "thread-1")
    assert {:error, :invalid_thread_id} = CodexClient.request_compact(port(), "")
  end

  test "the app-server RPC parser returns the completed compacted thread" do
    {:ok, frame} = CodexClient.build_request("thr_original")
    payload = response(frame["id"], %{})

    assert {:ok, %{}} =
             AppServerRpc.handle_response(port(), frame["id"], payload, 10, "Codex")
  end

  test "the app-server RPC parser preserves server errors and the client reports timeout" do
    {:ok, frame} = CodexClient.build_request("thr_original")
    payload = Jason.encode!(%{"id" => frame["id"], "error" => %{"code" => -32000, "message" => "compaction rejected"}})

    assert {:error, {:response_error, %{"message" => "compaction rejected"}}} =
             AppServerRpc.handle_response(port(), frame["id"], payload, 10, "Codex")

    assert {:error, :response_timeout} = CodexClient.request_compact(port(), "thr_original", timeout_ms: 10)
  end

  test "waits for the correlated thread/compacted completion event" do
    {:ok, frame} = CodexClient.build_request("thr_original")
    assert {:ok, _} = AppServerRpc.handle_response(port(), frame["id"], Jason.encode!(%{"id" => frame["id"], "result" => %{}}), 10, "Codex")

    # The real client cannot report completed based on a successful empty RPC
    # response. Without the matching notification its request must fail.
    assert {:error, :response_timeout} = CodexClient.request_compact(port(), "thr_original", timeout_ms: 10)
  end

  test "uses the live JSON-RPC wire and accepts completion before the response" do
    {port, dir} = server_port("notification-first")

    on_exit(fn ->
      File.rm_rf(dir)
      if Port.info(port), do: Port.close(port)
    end)

    assert {:ok, %{thread_id: "thr_original", turn_id: "turn_compact"}} =
             CodexClient.request_compact(port, "thr_original", timeout_ms: 500, on_status: fn status, _thread_id, _detail -> send(self(), {:status, status}) end)

    assert_received {:status, :pending}
    assert_received {:status, :completed}
  end

  test "keeps reading after an empty response until the completion notification arrives" do
    {port, dir} = server_port("response-first")

    on_exit(fn ->
      File.rm_rf(dir)
      if Port.info(port), do: Port.close(port)
    end)

    assert {:ok, %{thread_id: "thr_original", turn_id: "turn_compact"}} =
             CodexClient.request_compact(port, "thr_original", timeout_ms: 500)
  end

  test "reports server failure and a missing completion notification" do
    {failure_port, failure_dir} = server_port("failure")

    on_exit(fn ->
      File.rm_rf(failure_dir)
      if Port.info(failure_port), do: Port.close(failure_port)
    end)

    assert {:error, {:response_error, %{"message" => "compaction rejected"}}} =
             CodexClient.request_compact(failure_port, "thr_original", timeout_ms: 100)

    {timeout_port, timeout_dir} = server_port("no-completion")

    on_exit(fn ->
      File.rm_rf(timeout_dir)
      if Port.info(timeout_port), do: Port.close(timeout_port)
    end)

    assert {:error, :compaction_completion_timeout} =
             CodexClient.request_compact(timeout_port, "thr_original", timeout_ms: 100)
  end

  defp port do
    port = Port.open({:spawn, "sleep 1"}, [:binary, {:line, 65_536}])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  defp server_port(mode) do
    dir = Aiur.TestSupport.tmp_root!("aiur_codex_compaction_server")
    File.mkdir_p!(dir)
    path = Path.join(dir, "server.py")

    File.write!(path, """
    import json, sys
    request = json.loads(sys.stdin.readline())
    thread_id = request["params"]["threadId"]
    response = {"id": request["id"], "result": {}}
    notification = {"method": "thread/compacted", "params": {"threadId": thread_id, "turnId": "turn_compact"}}
    mode = #{inspect(mode)}
    if mode == "failure":
        print(json.dumps({"id": request["id"], "error": {"code": -32000, "message": "compaction rejected"}}), flush=True)
    elif mode == "no-completion":
        print(json.dumps(response), flush=True)
    elif mode == "response-first":
        print(json.dumps(response), flush=True)
        print(json.dumps(notification), flush=True)
    else:
        print(json.dumps(notification), flush=True)
        print(json.dumps(response), flush=True)
    """)

    executable = System.find_executable("python3") || raise "python3 is required for JSON-RPC wire tests"
    port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, :use_stdio, {:line, 65_536}, args: [path]])
    {port, dir}
  end

  defp response(id, result), do: Jason.encode!(%{"id" => id, "result" => result})
end
