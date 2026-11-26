defmodule Aiur.AppServer.RelayTurnReapTest do
  use Aiur.TestSupport

  alias Aiur.Codex.CodingAgent
  alias Aiur.Workflow

  # #4730: a tool command backgrounded with setsid, then orphaned, left the
  # provider's process group and outlived the turn. The loop sleeps instead of
  # spinning: tests never generate real CPU load.
  test "a detached loop started by an agent command is gone once the turn ends" do
    root = Aiur.TestSupport.tmp_root!("relay-turn-reap")
    workspace = Path.join(root, "issue-1")
    File.mkdir_p!(workspace)
    script = Path.join(workspace, "fake.py")
    File.write!(script, fake_server())
    pid_file = Path.join(workspace, "loop.pid")

    on_exit(fn ->
      # Without the fix the loop survives; never leave it behind.
      with {:ok, pid} <- File.read(pid_file), do: System.cmd("kill", ["-KILL", String.trim(pid)], stderr_to_stdout: true)
      Aiur.TestCleanup.rm_rf!(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex", workspace_root: root, command: "python3 -u #{Aiur.Shell.escape(script)}")
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "agent:\n", "agent:\n  relay: true\n"))
    Aiur.WorkflowStore.force_reload()
    assert {:ok, session} = CodingAgent.start_session(workspace)
    assert is_pid(session.port)

    try do
      assert {:ok, %{result: :turn_completed}} = CodingAgent.run_turn(session, "spin", %{id: "1", identifier: "T-1", title: "fake"})
      loop = pid_file |> File.read!() |> String.trim()
      assert eventually(fn -> not alive?(loop) end), "detached loop #{loop} outlived the turn"
    after
      CodingAgent.stop_session(session)
    end
  end

  defp alive?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(")") |> List.last() |> String.split() |> hd() != "Z"
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end

  defp fake_server do
    ~S"""
    import json,os,subprocess,sys,time
    def emit(value): print(json.dumps(value),flush=True)
    detach = "(setsid timeout 30 sh -c 'echo $$ > loop.pid; while :; do sleep 0.2; done' </dev/null >/dev/null 2>&1 &)"
    for line in sys.stdin:
      request=json.loads(line)
      method=request.get('method')
      identity=request.get('id')
      if method=='initialize':
        emit({'id':identity,'result':{'server':{'name':'fake'}}})
      elif method in ('thread/start','thread/resume'):
        emit({'id':identity,'result':{'thread':{'id':'thread-1'}}})
      elif method=='turn/start':
        emit({'id':identity,'result':{'turn':{'id':'turn-1'}}})
        subprocess.run(['bash','-c',detach])
        while not os.path.exists('loop.pid') or not open('loop.pid').read().strip(): time.sleep(0.01)
        emit({'method':'turn/completed','params':{'turn':{'id':'turn-1','status':'completed'}}})
    """
  end
end
