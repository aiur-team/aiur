defmodule Aiur.Claude.PauseTurnTest do
  # #4696: a pause must stop a Claude app-server turn. aiur-claude reports
  # `turn/completed` with the status flat on `params`, not under `params.turn`.
  use Aiur.TestSupport

  alias Aiur.Claude.CodingAgent, as: ClaudeAgent

  @interrupted ~s({"jsonrpc":"2.0","method":"turn/completed","params":{"turn_id":"u1","thread_id":"t1","status":"interrupted","items_count":1}})
  @no_active_turn ~s({"jsonrpc":"2.0","id":%s,"error":{"code":-32004,"message":"No active turn to interrupt."}})

  test "pause interrupts the running Claude turn and reports paused" do
    {result, frames} = run_paused_turn("interrupted", "printf '%s\\n' '#{@interrupted}'")

    assert {:paused, %{control: %{request_id: 91, generation: 4}, turn_id: "u1"}} = result
    assert Enum.any?(frames, &(&1["method"] == "turn/interrupt"))
  end

  test "pause reports paused when Claude has no active turn to interrupt" do
    {result, _frames} = run_paused_turn("no-active-turn", ~s(printf '#{@no_active_turn}\\n' "$request_id"))

    assert {:paused, %{control: %{request_id: 91, generation: 4}, turn_id: "u1"}} = result
  end

  defp run_paused_turn(name, interrupt_reply) do
    root = Aiur.TestSupport.tmp_root!("aiur-claude-pause-#{name}")
    workspace = Path.join(root, "agent-1")
    File.mkdir_p!(workspace)
    frames = Path.join(workspace, "frames.jsonl")
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      workspace_root: root,
      command: fake_app_server(frames, interrupt_reply)
    )

    test_pid = self()

    # Pause once the provider reports the turn running, as the orchestrator would.
    on_message = fn
      %{payload: %{"method" => "turn/started"}} -> send(test_pid, {:pause_agent, 91, 4})
      _message -> :ok
    end

    assert {:ok, session} = ClaudeAgent.start_session(workspace)
    result = ClaudeAgent.run_turn(session, "do the thing", %{id: 1, identifier: "test:pause", title: "pause"}, on_message: on_message)
    ClaudeAgent.stop_session(session)

    {result, frames |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)}
  end

  defp fake_app_server(frames, interrupt_reply) do
    init = ~s({"jsonrpc":"2.0","id":1,"result":{"server":{"name":"fake"}}})
    thread = ~s({"jsonrpc":"2.0","id":2,"result":{"thread":{"id":"t1"}}})
    turn = ~s({"jsonrpc":"2.0","id":3,"result":{"turn":{"id":"u1"}}})
    started = ~s({"jsonrpc":"2.0","method":"turn/started","params":{"turn_id":"u1","thread_id":"t1"}})

    "while IFS= read -r line; do echo \"$line\" >> #{frames}; " <>
      ~s{request_id=$(printf '%s' "$line" | grep -o '^{"id":[0-9]*' | cut -d: -f2); } <>
      "case \"$line\" in " <>
      "*'\"initialize\"'*) echo '#{init}' ;; " <>
      "*'\"thread/start\"'*) echo '#{thread}' ;; " <>
      "*'\"turn/start\"'*) echo '#{turn}'; echo '#{started}' ;; " <>
      "*'\"turn/interrupt\"'*) #{interrupt_reply} ;; " <>
      "esac; done"
  end
end
