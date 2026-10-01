defmodule Aiur.Muse.TurnFailureTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport, only: [receive_barrier: 1]
  import Aiur.TestSupport.MuseFixture, only: [run_fixture: 2, frames: 1]

  alias Aiur.Muse.{Session, Transcript, Turn, TurnControl}

  for {label, callback, reason} <- [
        {"returned error", quote(do: fn _ -> {:error, :unavailable} end), :unavailable},
        {"raised error", quote(do: fn _ -> raise "queue acknowledgement unavailable" end), {:callback_exception, RuntimeError}}
      ] do
    @tag :tmp_dir
    test "accepted turn with #{label} from delivery callback stays outcome uncertain", %{tmp_dir: dir} do
      command = delivery_fixture_command(dir)
      {:ok, session} = Session.start(dir, config: %{}, command: command)

      try do
        assert {:error, {:provider_delivery_ack_failed, %{turn_id: "turn-1", cause: unquote(Macro.escape(reason)), native_outcome: :completed}}} =
                 Turn.run(session, "Implement it", %{id: 1, identifier: "MUSE-1"}, on_provider_delivery: unquote(callback))

        assert Enum.count(frames(dir), &(&1["method"] == "turn/start")) == 1
      after
        Session.stop(session)
      end
    end
  end

  defp delivery_fixture_command(dir) do
    path = Path.join(dir, "delivery_fixture.py")

    File.write!(path, """
    import json, sys
    from pathlib import Path

    log = Path(#{inspect(Path.join(dir, "frames.ndjson"))})
    for line in sys.stdin:
        frame = json.loads(line)
        with log.open('a') as out:
            out.write(json.dumps(frame) + '\\n')
        method = frame.get('method')
        if method == 'initialize':
            result = {'schema': {'version': 1}, 'grantedCapabilities': ['sessionMcp']}
        elif method == 'session/start':
            result = {'session': {'sessionId': 'native-session'}, 'viewCursor': 'view-0'}
        elif method == 'usage/read':
            result = {'usage': None}
        elif method == 'turn/start':
            result = {'commandId': frame['params']['commandId'], 'status': 'accepted', 'disposition': 'started', 'startedNewTurn': True, 'turnId': 'turn-1'}
            print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}), flush=True)
            print(json.dumps({'jsonrpc': '2.0', 'method': 'turn/completed', 'params': {'sessionId': 'native-session', 'turnId': 'turn-1', 'terminal': 'completed', 'viewCursor': 'view-2', 'sourceRange': {}}}), flush=True)
            continue
        else:
            continue
        print(json.dumps({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}), flush=True)
    """)

    "python3 " <> Aiur.Shell.escape(path)
  end

  # These paths already fail closed; guard against future optimistic success.
  for {mode, reason} <- [
        {"interrupt_error", {:native_interrupt_rejected, %{"code" => -32_030, "message" => "rejected"}}},
        {"interrupt_invalid", {:native_interrupt_rejected, :invalid_turn_interrupt_receipt}}
      ] do
    @tag :tmp_dir
    test "#{mode} cannot acknowledge an operator pause", %{tmp_dir: dir} do
      task = run_fixture(dir, unquote(mode))
      receive_barrier({:turn_ready, owner})
      send(owner, {:pause_agent, 77, 4})
      assert Task.await(task, :infinity) == {:error, unquote(Macro.escape(reason))}
      assert List.last(frames(dir))["method"] == "turn/interrupt"
    end
  end

  @tag :tmp_dir
  test "unsupported native input is rejected and cancellation preserves its cause", %{tmp_dir: dir} do
    task = run_fixture(dir, "user_input")
    assert Task.await(task, :infinity) == {:error, :native_user_input_required}

    assert %{"id" => "input-1", "error" => %{"code" => -32_603, "message" => "Aiur cannot present this native request"}} =
             Enum.find(frames(dir), &(&1["id"] == "input-1"))

    assert List.last(frames(dir))["method"] == "turn/interrupt"
    receive_barrier({:event, %{reason: :native_user_input_required} = event})
    assert event.event == :notification
    assert {:ok, %{role: :system, body: body}} = Transcript.extract(event, "turn-1")
    assert body == "Muse requested a native input dialog that Aiur cannot display. Cancellation requested; send your instructions in chat after the turn stops."
  end

  test "normal completion racing unsupported-input cancellation preserves the error" do
    state = %{session: %{thread_id: "native-session"}, turn_id: "turn-1", interrupt: %{action: {:error, :native_user_input_required}}}

    assert TurnControl.finish(state, {:completed, %{"viewCursor" => "view-2"}}) ==
             {:error, :native_user_input_required}
  end

  @tag :tmp_dir
  test "another session's input request cannot interrupt the active turn", %{tmp_dir: dir} do
    assert {:ok, %{result: :turn_completed}} = Task.await(run_fixture(dir, "user_input_foreign"), :infinity)
    refute Enum.any?(frames(dir), &(&1["method"] == "turn/interrupt" or &1["id"] == "input-1"))
    refute_received {:event, %{reason: :native_user_input_required}}, 0
  end
end
