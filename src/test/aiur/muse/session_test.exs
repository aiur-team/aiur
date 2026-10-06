defmodule Aiur.Muse.SessionTest do
  use ExUnit.Case, async: true

  alias Aiur.Muse.Session

  @tag :tmp_dir
  test "starts a scoped MCP gateway and native session after handshake", %{tmp_dir: dir} do
    command = fixture(dir, "start")

    assert {:ok, session} =
             Session.start(dir,
               config: %{},
               command: command,
               model: "model-1",
               identifier: "MUSE-TEST",
               timeout_ms: 2_000,
               on_provider_started: fn provider ->
                 send(self(), {:provider, provider})
                 :ok
               end,
               on_process_group_started: fn group ->
                 send(self(), {:group, group})
                 :ok
               end
             )

    assert session.thread_id == "native-session"
    assert session.view_cursor == "view-1"
    assert session.resumed == false
    assert session.approval_mode == "onRequest"
    assert session.model == "native-model"
    assert is_pid(session.gateway)
    assert Process.alive?(session.gateway)
    assert_receive {:provider, %{root_pid: pid, process_group_id: group}}, 1000
    assert_receive {:group, ^group}, 1000
    assert is_integer(pid)

    assert :ok = Session.stop(session)
    refute Process.alive?(session.gateway)

    assert Jason.decode!(File.read!(Path.join(dir, "args.json"))) == []

    frames = read_frames(dir)
    assert Enum.map(frames, & &1["method"]) == ["initialize", "initialized", "session/start", "usage/read"]
    start = Enum.find(frames, &(&1["method"] == "session/start"))["params"]
    assert start["modelId"] == "model-1"
    assert start["approvalMode"] == "onRequest"

    assert %{"transport" => "streamableHttp", "url" => "http://127.0.0.1:" <> _, "headers" => %{"Authorization" => "Bearer " <> _}} =
             start["config"]["mcpServers"]["aiur"]
  end

  @tag :tmp_dir
  test "workspace trust requires an explicit launch setting", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, config: %{"trust_workspace" => true}, command: fixture(dir, "start"), timeout_ms: 2_000)
    assert :ok = Session.stop(session)
    assert Jason.decode!(File.read!(Path.join(dir, "args.json"))) == ["--trust-workspace"]
  end

  @tag :tmp_dir
  test "resume success keeps the native identity and refreshes MCP config", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, config: %{}, command: fixture(dir, "resume"), resume_thread_id: "native-session", timeout_ms: 2_000)
    assert session.resumed == true
    assert session.thread_id == "native-session"
    assert :ok = Session.stop(session)

    frames = read_frames(dir)
    assert Enum.map(frames, & &1["method"]) == ["initialize", "initialized", "session/resume", "usage/read"]
    resume = Enum.find(frames, &(&1["method"] == "session/resume"))["params"]
    assert resume["sessionId"] == "native-session"
    assert resume["excludeItems"] == true
    assert get_in(resume, ["config", "mcpServers", "aiur", "mode"]) == "required"
  end

  @tag :tmp_dir
  test "a missing stored session falls back to a clean native start", %{tmp_dir: dir} do
    assert {:ok, session} = Session.start(dir, config: %{}, command: fixture(dir, "resume_fail"), resume_thread_id: "old-session", timeout_ms: 2_000)
    assert session.resumed == false
    assert session.thread_id == "native-session"
    assert :ok = Session.stop(session)
    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "initialized", "session/resume", "session/start", "usage/read"]
  end

  for {mode, expected} <- [
        {"resume_busy", {:msp_error, %{"code" => -32_021, "message" => "session in use"}}},
        {"resume_mismatch", :resume_session_mismatch},
        {"resume_timeout", :response_timeout}
      ] do
    @tag :tmp_dir
    test "#{mode} preserves the failure instead of creating a different conversation", %{tmp_dir: dir} do
      result = Session.start(dir, config: %{}, command: fixture(dir, unquote(mode)), resume_thread_id: "old-session", timeout_ms: 1_000)
      # Clean up the deliberately wrong implementation before asserting failure.
      if match?({:ok, _}, result), do: Session.stop(elem(result, 1))
      assert result == {:error, unquote(Macro.escape(expected))}
      assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize", "initialized", "session/resume"]
    end
  end

  @tag :tmp_dir
  test "unsupported handshake cleans up the gateway and process", %{tmp_dir: dir} do
    assert {:error, {:unsupported_schema_version, 2}} =
             Session.start(dir, config: %{}, command: fixture(dir, "schema_2"), timeout_ms: 2_000)

    assert Enum.map(read_frames(dir), & &1["method"]) == ["initialize"]
  end

  test "rejects remote workers before checking the local workspace" do
    assert {:error, :remote_worker_unsupported} = Session.start("/does-not-exist", worker_host: "worker")
  end

  defp read_frames(dir) do
    dir
    |> Path.join("frames.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp fixture(dir, mode) do
    script = Path.join(dir, "msp_fixture.py")

    File.write!(script, """
    import json, sys
    from pathlib import Path

    mode = #{inspect(mode)}
    Path(#{inspect(Path.join(dir, "args.json"))}).write_text(json.dumps(sys.argv[1:]))
    frames = Path(#{inspect(Path.join(dir, "frames.ndjson"))})
    for line in sys.stdin:
        frame = json.loads(line)
        with frames.open('a') as output:
            output.write(json.dumps(frame) + '\\n')
        method = frame['method']
        if method == 'initialized':
            continue
        if method == 'initialize':
            result = {'schema': {'version': 2 if mode == 'schema_2' else 1}, 'grantedCapabilities': ['sessionMcp']}
        elif method == 'session/resume' and mode == 'resume_fail':
            print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32020, 'message': 'missing'}}), flush=True)
            continue
        elif method == 'session/resume' and mode == 'resume_busy':
            print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32021, 'message': 'session in use'}}), flush=True)
            continue
        elif method == 'session/resume' and mode == 'resume_timeout':
            continue
        else:
            result = {'session': {'sessionId': 'native-session', 'modelId': 'native-model', 'approvalMode': {'mode': 'onRequest'}}, 'viewCursor': 'view-1'}
        print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}), flush=True)
    """)

    "python3 #{script}"
  end
end
