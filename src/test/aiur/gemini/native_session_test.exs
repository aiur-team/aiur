defmodule Aiur.Gemini.NativeSessionTest do
  use ExUnit.Case, async: true

  alias Aiur.Gemini.{ModelCatalog, Protocol, Session, Transcript, Turn}

  @tag :tmp_dir
  test "ACP handshake creates an exact session with a private HTTP MCP route", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "normal"), timeout_ms: 2_000)
    assert session.thread_id == "gemini-session"
    assert session.resumed == false
    assert session.model == "gemini-auto"
    assert session.model_catalog == [%{"modelId" => "gemini-auto"}, %{"modelId" => "gemini-pro"}]

    [initialize, create] = read_frames(dir)
    assert initialize["method"] == "initialize"
    assert initialize["params"]["protocolVersion"] == 1
    assert create["method"] == "session/new"
    assert create["params"]["cwd"] == dir

    assert [%{"type" => "http", "name" => "aiur", "url" => "http://127.0.0.1:" <> _, "headers" => [%{"name" => "Authorization", "value" => "Bearer " <> _}]}] =
             create["params"]["mcpServers"]

    assert :ok = Session.stop(session)
    refute Process.alive?(session.gateway)
  end

  @tag :tmp_dir
  test "only native catalog models can be selected", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "normal"), model: "gemini-pro", timeout_ms: 2_000)
    assert session.model == "gemini-pro"
    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "session/new", "session/set_model"]

    assert {:ok, ["gemini-auto", "gemini-pro"]} =
             ModelCatalog.extract(%{"models" => %{"availableModels" => session.model_catalog}})

    assert :ok = Session.stop(session)

    assert {:error, {:gemini_model_unavailable, "invented"}} =
             Session.start(dir, command: fixture(dir, "normal"), model: "invented", timeout_ms: 2_000)
  end

  @tag :tmp_dir
  test "ambient auto approval is reset to native default before dispatch", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "yolo"), timeout_ms: 2_000)
    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "session/new", "session/set_mode"]
    assert List.last(read_frames(dir))["params"]["modeId"] == "default"
    assert :ok = Session.stop(session)
  end

  @tag :tmp_dir
  test "exact stored session is loaded without starting another conversation", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "normal"), resume_thread_id: "stored-session", timeout_ms: 2_000)
    assert session.thread_id == "stored-session"
    assert session.resumed == true
    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "session/load"]
    assert :ok = Session.stop(session)
  end

  @tag :tmp_dir
  test "authentication failure cannot silently create a fresh session", %{tmp_dir: dir} do
    assert {:error, {:acp_error, %{"message" => "authentication required"}}} =
             Session.start(dir, command: fixture(dir, "auth_fail"), resume_thread_id: "stored-session", timeout_ms: 2_000)

    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "session/load"]
  end

  @tag :tmp_dir
  test "confirmed missing exact session starts clean, without a latest-session guess", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "missing"), resume_thread_id: "stored-session", timeout_ms: 2_000)
    assert session.thread_id == "gemini-session"
    assert session.resumed == false
    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "session/load", "session/new"]
    assert :ok = Session.stop(session)
  end

  @tag :tmp_dir
  test "prompt streams text, shows a native permission, applies only the selected choice", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, command: fixture(dir, "normal"), timeout_ms: 2_000)
    owner = self()

    on_message = fn message ->
      send(owner, {:gemini_message, message})

      if get_in(message, [:payload, "method"]) == "session/request_permission" do
        Process.put(:permission_token, message.gemini_permission_token)
        send(owner, {:agent_queue_updated, "GEMINI-TEST", 1, false})
      end
    end

    response = fn "/approve" ->
      token = Process.get(:permission_token)
      {:deliver_text, "/approve #{token} reject", fn details -> send(owner, {:approved, details}) end, fn reason -> send(owner, {:approval_failed, reason}) end}
    end

    assert {:ok, %{result: :turn_completed, thread_id: "gemini-session"}} =
             Turn.run(session, "say hello", %{identifier: "GEMINI-TEST"}, on_message: on_message, on_operator_response: response, tool_executor: fn _, _ -> %{} end, turn_timeout_ms: 2_000)

    assert_receive {:approved, %{decision: "reject", confirmation: :request_only}}
    assert_received {:gemini_message, %{payload: %{"method" => "session/update"}}}
    assert_received {:gemini_message, %{payload: %{"method" => "session/request_permission"}}}
    assert_received {:gemini_message, %{payload: %{"method" => "session/prompt", "result" => %{"_meta" => %{"quota" => %{"token_count" => %{"input_tokens" => 12, "output_tokens" => 5}}}}}}}

    assert [%{"method" => "session/prompt"} = prompt | _] =
             read_frames(dir) |> Enum.drop(2)

    assert prompt["params"]["sessionId"] == "gemini-session"
    assert prompt["params"]["prompt"] == [%{"type" => "text", "text" => "say hello"}]
    assert %{"result" => %{"outcome" => %{"optionId" => "reject"}}} = List.last(read_frames(dir))
    assert :ok = Session.stop(session)
  end

  test "ACP frames reject unsupported MCP or load capability and render unknown usage without zero" do
    assert {:error, :gemini_http_mcp_unsupported} =
             Protocol.validate_initialize(%{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true, "mcpCapabilities" => %{"http" => false}}})

    assert {:error, :gemini_session_load_unsupported} =
             Protocol.validate_initialize(%{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => false, "mcpCapabilities" => %{"http" => true}}})

    message = %{
      payload: %{
        "method" => "session/update",
        "params" => %{
          "sessionId" => "s",
          "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "hello"}}
        }
      }
    }

    assert {:ok, %{role: :assistant, body: "hello", kind: :assistant_delta}} = Transcript.extract(message, nil)
  end

  @tag :tmp_dir
  test "an incompatible CLI and unsupported dispatch controls fail before a prompt", %{tmp_dir: dir} do
    assert {:error, {:unsupported_acp_version, 2}} =
             Session.start(dir, command: fixture(dir, "unsupported"), timeout_ms: 2_000)

    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize"]

    assert {:error, :gemini_effort_unsupported} = Session.start(dir, effort: "high")
    assert {:error, :remote_worker_unsupported} = Session.start(dir, worker_host: "host")
    assert {:error, :remote_control_unsupported} = Session.start(dir, remote_control: true)
  end

  defp read_frames(dir) do
    dir |> Path.join("frames.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp fixture(dir, mode) do
    script = Path.join(dir, "acp_fixture.py")

    File.write!(script, """
    import json, sys
    from pathlib import Path

    mode = #{inspect(mode)}
    frames = Path(#{inspect(Path.join(dir, "frames.ndjson"))})
    prompt_id = None
    for line in sys.stdin:
        frame = json.loads(line)
        with frames.open('a') as output:
            output.write(json.dumps(frame) + '\\n')
        method = frame.get('method')
        if method == 'initialize':
            result = {'protocolVersion': 2 if mode == 'unsupported' else 1, 'agentInfo': {'name': 'gemini-cli', 'version': '0.61.0'}, 'agentCapabilities': {'loadSession': True, 'mcpCapabilities': {'http': True}}}
        elif method == 'session/load' and mode == 'auth_fail':
            print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32000, 'message': 'authentication required'}}), flush=True)
            continue
        elif method == 'session/load' and mode == 'missing':
            print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32603, 'message': 'Invalid session identifier "stored-session". Searched for sessions.'}}), flush=True)
            continue
        elif method == 'session/load':
            result = {'modes': {'currentModeId': 'default'}, 'models': {'currentModelId': 'gemini-auto', 'availableModels': [{'modelId': 'gemini-auto'}, {'modelId': 'gemini-pro'}]}}
        elif method == 'session/new':
            result = {'sessionId': 'gemini-session', 'modes': {'currentModeId': 'yolo' if mode == 'yolo' else 'default'}, 'models': {'currentModelId': 'gemini-auto', 'availableModels': [{'modelId': 'gemini-auto'}, {'modelId': 'gemini-pro'}]}}
        elif method == 'session/set_model':
            result = {}
        elif method == 'session/set_mode':
            result = {}
        elif method == 'session/prompt':
            prompt_id = frame['id']
            session = frame['params']['sessionId']
            print(json.dumps({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'hello'}}}}), flush=True)
            print(json.dumps({'jsonrpc':'2.0','id':77,'method':'session/request_permission','params':{'sessionId':session,'toolCall':{'title':'write file'},'options':[{'optionId':'allow','name':'Allow'},{'optionId':'reject','name':'Reject'}]}}), flush=True)
            continue
        elif frame.get('id') == 77:
            print(json.dumps({'jsonrpc':'2.0','id':prompt_id,'result':{'stopReason':'end_turn','_meta':{'quota':{'token_count':{'input_tokens':12,'output_tokens':5},'model_usage':[]}}}}), flush=True)
            continue
        else:
            continue
        print(json.dumps({'jsonrpc':'2.0','id':frame['id'],'result':result}), flush=True)
    """)

    "python3 #{script}"
  end
end
