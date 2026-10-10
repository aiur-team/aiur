defmodule Aiur.AppServer.RelayAdapterTest do
  use Aiur.TestSupport

  alias Aiur.Workflow

  for {backend, module} <- [{"codex", Aiur.Codex.CodingAgent}, {"claude", Aiur.Claude.CodingAgent}] do
    test "#{backend} completes the same fake turn through direct and relay transports" do
      root = Aiur.TestSupport.tmp_root!("relay-adapter")
      workspace = Path.join(root, "issue-1")
      File.mkdir_p!(workspace)
      script = Path.join(workspace, "fake.py")
      File.write!(script, fake_server())
      on_exit(fn -> File.rm_rf!(root) end)

      results =
        for enabled <- [false, true] do
          write_workflow_file!(Workflow.workflow_file_path(), agent_kind: unquote(backend), workspace_root: root, command: "python3 -u #{Aiur.Shell.escape(script)}")
          path = Workflow.workflow_file_path()
          File.write!(path, String.replace(File.read!(path), "agent:\n", "agent:\n  relay: #{enabled}\n"))
          Aiur.WorkflowStore.force_reload()
          assert {:ok, session} = unquote(module).start_session(workspace)
          assert is_pid(session.port) == enabled
          parent = self()

          try do
            assert {:ok, result} =
                     unquote(module).run_turn(session, "do the thing", %{id: "1", identifier: "T-1", title: "fake"}, on_message: fn message -> send(parent, {:provider_message, message}) end)

            assert result.result == :turn_completed
            {result.result, drain_events([])}
          after
            unquote(module).stop_session(session)
          end
        end

      assert Enum.at(results, 0) == Enum.at(results, 1)
      {_, events} = hd(results)
      assert Enum.any?(events, fn {_event, details} -> get_in(details, [:payload, "params", "delta"]) == "hello" end)
    end
  end

  defp drain_events(events) do
    receive do
      {:provider_message, message} ->
        # Provider PIDs are intentionally different; compare actual event payloads.
        drain_events([
          {message.event,
           Map.drop(message, [
             :event,
             :timestamp,
             :provider_pid,
             :codex_app_server_pid,
             :claude_app_server_pid,
             :agent_process_group_id,
             :relay_pid,
             :pgid,
             :directory,
             :generation,
             :relay_id,
             :spawn_nonce,
             :journal_end,
             :acked_offset
           ])}
          | events
        ])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp fake_server do
    ~S"""
    import json,sys
    def emit(value): print(json.dumps(value),flush=True)
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
        emit({'method':'item/agentMessage/delta','params':{'delta':'hello','turnId':'turn-1'}})
        emit({'method':'turn/completed','params':{'turn':{'id':'turn-1','status':'completed'}}})
    """
  end
end
