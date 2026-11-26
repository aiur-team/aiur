defmodule Aiur.Muse.SteerTest do
  use ExUnit.Case, async: true
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Muse.{CodingAgent, Protocol, Session, Turn}

  test "steer frame targets exact turn and preserves command identity" do
    frame = Protocol.turn_steer_frame(9, "session", "turn", "0.1", command_id: "command", reasoning_effort: "high")

    assert frame == %{
             "jsonrpc" => "2.0",
             "id" => 9,
             "method" => "turn/steer",
             "params" => %{
               "commandId" => "command",
               "sessionId" => "session",
               "expectedTurnId" => "turn",
               "input" => [%{"type" => "text", "text" => "0.1"}],
               "reasoningEffort" => "high"
             }
           }

    assert Protocol.turn_steer_frame(10, "session", "turn", "text")["params"]["commandId"] =~ ~r/^[0-9a-f-]{14}7[0-9a-f-]{21}$/
  end

  test "steer receipt requires matching command, accepted status and turn id" do
    receipt = %{"commandId" => "command", "status" => "accepted", "turnId" => "turn"}
    assert {:accepted, ^receipt} = Protocol.turn_steer_result(receipt, "command")

    for invalid <- [Map.delete(receipt, "turnId"), Map.put(receipt, "commandId", "other"), Map.put(receipt, "status", "rejected")] do
      assert {:error, :invalid_turn_steer_receipt} = Protocol.turn_steer_result(invalid, "command")
    end
  end

  test "adapter refuses invalid input and propagates closed ports" do
    assert {:error, :no_active_turn} = CodingAgent.steer(%{}, %{kind: :text, body: "hello"}, nil)
    assert {:error, :invalid_operator_message} = CodingAgent.steer(%{}, %{kind: :text, body: ""}, "turn")
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    Port.close(port)
    assert {:error, :port_closed} = CodingAgent.steer(%{port: port, thread_id: "session"}, %{kind: :text, body: "hello"}, "turn")
  end

  @tag :tmp_dir
  test "steer wake sends exactly one native steer without interrupting", %{tmp_dir: dir} do
    task = run(dir, "accepted")
    receive_barrier(:claimed)
    receive_barrier({:delivered, %{transport: :muse_msp, turn_id: "turn-1"}})
    assert {:ok, %{result: :turn_completed}} = Task.await(task, :infinity)
    frames = frames(dir)
    assert Enum.count(frames, &(&1["method"] == "turn/steer")) == 1
    refute Enum.any?(frames, &(&1["method"] == "turn/interrupt"))
    [steer] = Enum.filter(frames, &(&1["method"] == "turn/steer"))
    assert steer["params"]["expectedTurnId"] == "turn-1"
    assert steer["params"]["input"] == [%{"type" => "text", "text" => "0.1"}]
    refute_received :claimed
    refute_received {:failed, _}
    refute_received {:delivered, _}
  end

  for {mode, reason} <- [
        {"rejected", {:response_error, %{"code" => -32_001, "message" => "turn ended"}}},
        {"invalid", :invalid_turn_steer_receipt},
        {"wrong_turn", :invalid_turn_steer_receipt},
        {"lost", :parent_turn_completed}
      ] do
    @tag :tmp_dir
    test "#{mode} steer restores claim exactly once", %{tmp_dir: dir} do
      task = run(dir, unquote(mode))
      receive_barrier(:claimed)
      assert {:ok, %{result: :turn_completed}} = Task.await(task, :infinity)
      assert_received {:failed, unquote(Macro.escape(reason))}
      refute_received {:failed, _}
      refute_received {:delivered, _}
    end
  end

  @tag :tmp_dir
  test "pause preserves accepted steer and suppresses further claims", %{tmp_dir: dir} do
    task = run(dir, "pause")
    receive_barrier(:claimed)
    receive_barrier({:delivered, %{turn_id: "turn-1"}})
    assert {:paused, %{control: %{request_id: 77, generation: 4}}} = Task.await(task, :infinity)
    assert Enum.take(Enum.map(frames(dir), & &1["method"]), -2) == ["turn/steer", "turn/interrupt"]
    refute_received :claimed
    refute_received {:failed, _}
  end

  defp run(dir, mode) do
    owner = self()
    command = fixture(dir, mode)

    Task.async(fn ->
      {:ok, session} = Session.start(dir, config: %{}, command: command, timeout_ms: 30_000)

      try do
        Turn.run(session, "Implement it", %{identifier: "MUSE-1"},
          turn_timeout_ms: 30_000,
          on_message: fn _ -> :ok end,
          on_provider_delivery: fn _ -> send(self(), {:agent_queue_updated, "MUSE-1", 1, :steer}) end,
          on_steer_claim: fn ->
            send(owner, :claimed)
            # Both wakes precede the receipt and exercise the in-flight guard.
            send(self(), {:agent_queue_updated, "MUSE-1", 2, :steer})
            send(self(), {:agent_queue_updated, "OTHER", 3, :steer})

            if mode == "pause" do
              send(self(), {:pause_agent, 77, 4})
              send(self(), {:agent_queue_updated, "MUSE-1", 4, :steer})
            end

            {:deliver_text, "0.1", fn metadata -> send(owner, {:delivered, metadata}) end, fn reason -> send(owner, {:failed, reason}) end}
          end
        )
      after
        Session.stop(session)
      end
    end)
  end

  defp frames(dir), do: dir |> Path.join("frames.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp fixture(dir, mode) do
    path = Path.join(dir, "steer_fixture.py")

    File.write!(path, """
    import json, sys
    mode = #{inspect(mode)}
    def emit(frame):
        print(json.dumps(frame), flush=True)
    def terminal(kind):
        emit({'jsonrpc':'2.0','method':'turn/completed','params':{'sessionId':'native-session','turnId':'turn-1','terminal':kind,'viewCursor':'view-2','sourceRange':{}}})
    for line in sys.stdin:
        frame = json.loads(line)
        with open(#{inspect(Path.join(dir, "frames.ndjson"))}, 'a') as log:
            log.write(json.dumps(frame) + '\\n')
        method = frame.get('method')
        params = frame.get('params', {})
        if method == 'initialize':
            result = {'schema':{'version':1},'grantedCapabilities':['sessionMcp']}
        elif method == 'session/start':
            result = {'session':{'sessionId':'native-session'},'viewCursor':'view-0'}
        elif method in ['turn/start', 'turn/interrupt', 'turn/steer']:
            result = {'commandId':params['commandId'],'status':'accepted','turnId':'turn-1'}
            if method == 'turn/start':
                result.update({'disposition':'started','startedNewTurn':True})
            if method == 'turn/steer':
                if mode == 'lost':
                    terminal('completed')
                    continue
                if mode == 'rejected':
                    emit({'jsonrpc':'2.0','id':frame['id'],'error':{'code':-32001,'message':'turn ended'}})
                    terminal('completed')
                    continue
                if mode == 'invalid':
                    del result['turnId']
                if mode == 'wrong_turn':
                    result['turnId'] = 'other-turn'
        else:
            continue
        emit({'jsonrpc':'2.0','id':frame['id'],'result':result})
        if method == 'turn/steer' and mode != 'pause':
            emit({'jsonrpc':'2.0','id':frame['id'],'result':result})
            terminal('completed')
        if method == 'turn/interrupt':
            terminal('cancelled')
    """)

    "python3 " <> Aiur.Shell.escape(path)
  end
end
