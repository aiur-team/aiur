defmodule Aiur.TestSupport.MuseFixture do
  @moduledoc false
  alias Aiur.Muse.{Session, Turn}

  def run_fixture(dir, mode, turn_timeout_ms \\ 30_000) do
    test_owner = self()

    Task.async(fn ->
      {:ok, session} = Session.start(dir, config: %{}, command: fixture(dir, mode), timeout_ms: 30_000)

      try do
        Turn.run(session, "Implement it", %{id: 1, identifier: "MUSE-1"},
          turn_timeout_ms: turn_timeout_ms,
          on_message: fn event -> send(test_owner, {:event, event}) end,
          on_provider_delivery: fn _ -> send(test_owner, {:turn_ready, self()}) end,
          on_operator_response: fn "/approve" ->
            receive do
              {:executor_response, text} ->
                {:deliver_text, text, fn metadata -> send(test_owner, {:approval_delivered, metadata}) end, fn reason -> send(test_owner, {:approval_failed, reason}) end}
            after
              0 -> :noop
            end
          end,
          tool_executor: fn name, args ->
            send(test_owner, {:tool, self(), name, args})
            %{"success" => true, "output" => "from runner"}
          end
        )
      after
        Session.stop(session)
      end
    end)
  end

  def frames(dir) do
    dir
    |> Path.join("frames.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp fixture(dir, mode) do
    path = Path.join(dir, "msp_fixture.py")

    File.write!(path, """
    import json, sys, urllib.request
    from pathlib import Path

    mode = #{inspect(mode)}
    log = Path(#{inspect(Path.join(dir, "frames.ndjson"))})
    mcp = None

    def emit(frame):
        print(json.dumps(frame), flush=True)

    def terminal(kind):
        emit({'jsonrpc': '2.0', 'method': 'turn/completed', 'params': {'sessionId': 'native-session', 'turnId': 'turn-1', 'terminal': kind, 'viewCursor': 'view-2', 'sourceRange': {}}})

    for line in sys.stdin:
        frame = json.loads(line)
        with log.open('a') as out:
            out.write(json.dumps(frame) + '\\n')
        method = frame.get('method')
        if method is None:
            continue
        if method == 'initialized':
            continue
        if method == 'initialize':
            result = {'schema': {'version': 1}, 'grantedCapabilities': ['sessionMcp']}
        elif method == 'session/start':
            mcp = frame['params']['config']['mcpServers']['aiur']
            result = {'session': {'sessionId': 'native-session'}, 'viewCursor': 'view-0'}
        elif method == 'turn/start':
            result = {'commandId': frame['params']['commandId'], 'status': 'accepted', 'disposition': 'started', 'startedNewTurn': True, 'turnId': 'turn-1'}
            emit({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})
            if mode == 'complete':
                emit({'jsonrpc': '2.0', 'method': 'item/started', 'params': {'sessionId': 'native-session', 'viewCursor': 'view-1', 'item': {'itemId': 'item-1', 'kind': 'agentMessage', 'revision': 1}}})
                terminal('completed')
            elif mode == 'approval':
                emit({'jsonrpc': '2.0', 'method': 'approval/request', 'params': {'sessionId': 'native-session', 'turnId': 'turn-1', 'approvalId': 'approval-1', 'currentRequirementId': {'approvalId': 'approval-1', 'sourceIndex': 0}, 'availableChoices': [{'choiceId': 'allow_once', 'label': 'Allow once'}]}})
            elif mode == 'approval_replay':
                request = {'jsonrpc': '2.0', 'method': 'approval/request', 'params': {'sessionId': 'native-session', 'turnId': 'turn-1', 'viewCursor': 'approval-1', 'approvalId': 'approval-1', 'currentRequirementId': {'approvalId': 'approval-1', 'sourceIndex': 0}, 'availableChoices': [{'choiceId': 'allow_once', 'label': 'Allow once'}]}}
                emit(request)
                emit({'jsonrpc': '2.0', 'method': 'approval/resolved', 'params': {'sessionId': 'native-session', 'turnId': 'turn-1', 'viewCursor': 'approval-2', 'approvalId': 'approval-1', 'decision': 'approved'}})
                emit(request)
                emit({'jsonrpc': '2.0', 'method': 'item/started', 'params': {'sessionId': 'native-session', 'viewCursor': 'ready', 'item': {'itemId': 'ready-1', 'kind': 'agentMessage', 'revision': 1}}})
            elif mode in ['user_input', 'user_input_foreign']:
                session = 'foreign-session' if mode == 'user_input_foreign' else 'native-session'
                emit({'jsonrpc': '2.0', 'id': 'input-1', 'method': 'userInput/request', 'params': {'sessionId': session, 'turnId': 'turn-1'}})
                if mode == 'user_input_foreign':
                    terminal('completed')
            elif mode == 'bad_terminal':
                terminal('unknown')
            elif mode == 'mcp':
                body = json.dumps({'jsonrpc': '2.0', 'id': 8, 'method': 'tools/call', 'params': {'name': 'aiur_test', 'arguments': {'value': 42}}}).encode()
                req = urllib.request.Request(mcp['url'], body, headers={'Authorization': mcp['headers']['Authorization'], 'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=30) as response:
                    reply = json.load(response)
                assert reply['result']['content'][0]['text'] == 'from runner'
                terminal('completed')
            continue
        elif method == 'approval/decide':
            assert frame['params']['choiceId'] == 'allow_once'
            emit({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'status': 'accepted', 'commandId': frame['params']['commandId'], 'approvalId': 'approval-1', 'terminal': True}})
            emit({'jsonrpc': '2.0', 'method': 'approval/resolved', 'params': {'sessionId': 'native-session', 'approvalId': 'approval-1', 'decidedByCommandId': frame['params']['commandId'], 'decision': 'approved'}})
            terminal('completed')
            continue
        elif method == 'turn/interrupt':
            if mode == 'interrupt_error':
                emit({'jsonrpc': '2.0', 'id': frame['id'], 'error': {'code': -32030, 'message': 'rejected'}})
                continue
            if mode == 'interrupt_invalid':
                emit({'jsonrpc': '2.0', 'id': frame['id'], 'result': {'status': 'accepted', 'commandId': 'wrong-command', 'turnId': 'turn-1'}})
                continue
            result = {'commandId': frame['params']['commandId'], 'status': 'accepted', 'turnId': 'turn-1'}
            if mode == 'pause_completed':
                terminal('completed')
            emit({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})
            if mode != 'pause_completed':
                terminal('cancelled')
            continue
        else:
            continue
        emit({'jsonrpc': '2.0', 'id': frame['id'], 'result': result})
    """)

    "python3 " <> Aiur.Shell.escape(path)
  end
end
