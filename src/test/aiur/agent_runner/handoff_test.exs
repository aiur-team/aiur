defmodule Aiur.AgentRunner.HandoffTest do
  use Aiur.TestSupport

  import Aiur.Codex.TurnLoopTestSupport, only: [base_state: 0]
  alias Aiur.AgentRunner.Handoff
  alias Aiur.AgentRunner.Handoff.ProviderState
  alias Aiur.AgentRunner.SessionCleanup
  alias Aiur.AppServer.{Adapter, Transport, TurnLoop}
  alias Aiur.AppServer.RelayPort
  alias Aiur.Handoff.Fallback

  @tag :tmp_dir
  test "a detached mid-turn provider delivers an offline tool once and finishes after attach", %{tmp_dir: workspace} do
    gate = Path.join(workspace, "offline")
    script = Path.join(workspace, "provider.py")

    File.write!(script, """
    import os, sys, time, json
    while not os.path.exists(#{inspect(gate)}): time.sleep(0.01)
    print(json.dumps({'method':'item/tool/call','id':77,'params':{'tool':'aiur.echo','arguments':{'offline':True}}}), flush=True)
    response=json.loads(sys.stdin.readline())
    assert response['id']==77 and response['result']['success']
    print(json.dumps({'method':'turn/completed','params':{'turn':{'id':'turn-1','status':'completed'}}}), flush=True)
    time.sleep(10)
    """)

    parent = self()

    runner =
      spawn(fn ->
        {:ok, port} = Adapter.start_port(workspace, "python3 #{script}")
        session = %{backend: "codex", port: port, thread_id: "thread-1", workspace: workspace}
        context = %{issue: %Aiur.Issue{id: "1", identifier: "ISSUE-1"}, workspace: workspace, opts: [], turn_number: 1, max_turns: 1}
        Handoff.before_turn(session, context)
        send(parent, {:ready, self()})
        TurnLoop.receive_loop(session, Map.merge(base_state(), %{timeout_ms: 5_000, pending_line: ""}))
      end)

    assert_receive {:ready, ^runner}, 5_000
    Handoff.hold(runner)
    assert {:ok, record} = Handoff.snapshot(runner)
    on_exit(fn -> Fallback.stop(record) end)
    assert Handoff.decode(record["turn_state"]).current_turn_id == "turn-1"
    assert record["transport"]["kind"] == "relay"
    Process.exit(runner, :kill)
    File.touch!(gate)
    assert {:ok, session} = Handoff.attach(record, record["transport"]["generation"] + 1)
    on_exit(fn -> if Process.alive?(session.port), do: Transport.close(session.port) end)

    state =
      ProviderState.restore(Handoff.decode(record["turn_state"]),
        tool_executor: fn "aiur.echo", %{"offline" => true} ->
          send(parent, :offline_tool)
          %{"success" => true}
        end
      )

    assert TurnLoop.receive_loop(session, state) == {:ok, :turn_completed}
    assert_receive :offline_tool, 1_000
    refute_receive :offline_tool, 50
    assert {:error, _} = RelayPort.attach(record["transport"]["directory"], record["transport"]["generation"], record["transport"]["acked_offset"])
    Transport.close(session.port)
  end

  test "direct transports snapshot for per-agent fallback and retain normal shutdown cleanup" do
    parent = self()

    for {worker_host, expected} <- [{nil, "relay_protocol"}, {"remote-worker", "remote_worker"}] do
      runner =
        spawn(fn ->
          {:ok, port} = Adapter.start_port(File.cwd!(), "exec cat", fn _ -> :ok end, relay: false)
          session = %{backend: "codex", port: port, thread_id: "thread-1", workspace: File.cwd!(), worker_host: worker_host}
          Handoff.before_turn(session, %{worker_host: worker_host, workspace: File.cwd!()})
          send(parent, {:direct_ready, self()})

          try do
            TurnLoop.receive_loop(session, Map.merge(base_state(), %{timeout_ms: 5_000, pending_line: ""}))
          after
            SessionCleanup.stop(session, nil, fn current ->
              Transport.close(current.port)
              send(parent, {:direct_cleaned, self()})
              {:ok, :cleanup_proven}
            end)
          end
        end)

      assert_receive {:direct_ready, ^runner}, 5_000
      Handoff.hold(runner)
      assert {:ok, record} = Handoff.snapshot(runner)
      assert record["fallback_reason"] == expected
      assert record["transport"]["kind"] == "direct"
      assert record["transport"]["os_pid"] > 0
      Handoff.abort(runner)
      assert_receive {:direct_cleaned, ^runner}, 1_000
    end
  end

  test "portable snapshots preserve pending ids and provider sets without daemon capabilities" do
    callback = Handoff.callback(fn _ -> :ok end, %{handoff_item: %{id: 12}, handoff_issue: %Aiur.Issue{id: "1"}})
    state = %{pending_operator_requests: %{77 => %{on_success: callback}}, active_turn_ids: MapSet.new(["turn-1"]), owner: self()}
    restored = state |> Handoff.encode() |> Handoff.decode()
    assert restored.active_turn_ids == MapSet.new(["turn-1"])
    assert restored.pending_operator_requests[77].on_success.handoff_item.id == 12
    assert restored.owner == nil
  end

  test "a hold prevents the next turn and abort releases the barrier" do
    parent = self()

    runner =
      spawn(fn ->
        send(parent, :waiting)

        receive do
          :go -> :ok
        end

        Handoff.before_turn(%{}, %{})
        send(parent, :next_turn)
      end)

    assert_receive :waiting, 1_000
    Handoff.hold(runner)
    send(runner, :go)
    refute_receive :next_turn, 50
    Handoff.abort(runner)
    assert_receive :next_turn, 1_000
  end
end
