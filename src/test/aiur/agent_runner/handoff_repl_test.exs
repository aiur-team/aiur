defmodule Aiur.AgentRunner.HandoffReplTest do
  use Aiur.TestSupport

  alias Aiur.Claude.{HookSettings, Repl.HookTurn}

  test "adopt completes from a Stop present only in the durable spool without submitting input" do
    identifier = "HOOK-#{System.unique_integer([:positive])}"
    {:ok, path} = HookSettings.spool_path(identifier)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"aiur_hook_id" => "offline-stop", "hook_event_name" => "Stop", "session_id" => "session-preserved", "last_assistant_message" => "Finished offline"}) <> "\n")
    name = Module.concat(__MODULE__, "Tmux#{System.unique_integer([:positive])}")
    tmux = start_supervised!({Aiur.Tmux, transport: {:mock, self()}, name: name, session: "test"})
    session = %{backend: "claude-repl", tmux: tmux, pane_id: "%50", os_pid: 4242, identifier: identifier}
    task = Task.async(fn -> HookTurn.adopt(session, %{repl_acc: %{session_id: nil, message: nil, provider_delivered?: false}}, 0, []) end)
    assert_receive {:tmux_mock_out, "display-message" <> _}, 1_000
    send(tmux, {:tmux_mock_data, "%begin 1 1 0\n4242\n%end 1 1 0\n"})
    assert {:ok, result} = Task.await(task, 2_000)
    assert result.thread_id == "session-preserved"
    assert result.message == "Finished offline"
    refute_receive {:tmux_mock_out, "load-buffer" <> _}, 50
    refute_receive {:tmux_mock_out, "send-keys" <> _}, 50
  end
end
