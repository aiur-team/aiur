defmodule Aiur.Claude.Repl.HookSpoolTurnTest do
  use ExUnit.Case, async: false
  alias Aiur.Claude.{HookSettings, Repl.HookTurn}
  alias Aiur.Tmux

  test "a Stop written only to the spool completes the running turn" do
    dir = Path.join(System.tmp_dir!(), "spooled-turn-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:aiur, :runtime_state_dir)
    Application.put_env(:aiur, :runtime_state_dir, dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:aiur, :runtime_state_dir, previous), else: Application.delete_env(:aiur, :runtime_state_dir)
      File.rm_rf!(dir)
    end)

    name = Module.concat(__MODULE__, :"Tmux#{System.unique_integer([:positive])}")
    start_supervised!({Tmux, [transport: {:mock, self()}, name: name, session: "test"]})
    id = "OFFLINE-STOP-#{System.unique_integer([:positive])}"
    session = %{tmux: name, pane_id: "%50", os_pid: 4242, identifier: id}
    {:ok, path} = HookSettings.spool_path(id)
    File.mkdir_p!(Path.dirname(path))
    task = Task.async(fn -> HookTurn.run(session, "work", poll_interval_ms: 1) end)
    assert {:ok, %{result: :completed, thread_id: "offline-session", message: "offline done"}} = drive(name, path, task, id)
  end

  defp drive(tmux, path, task, id) do
    receive do
      {:tmux_mock_out, "send-keys -t %50 Enter"} ->
        # The spool is the only delivery path: never dispatch this Stop as a POST.
        raw = %{"hook_event_name" => "Stop", "session_id" => "offline-session", "last_assistant_message" => "offline done", "aiur_hook_id" => id}
        File.write!(path, Jason.encode!(raw) <> "\n")
        respond(tmux, "")
        drive(tmux, path, task, id)

      {:tmux_mock_out, "capture-pane" <> _} ->
        respond(tmux, "[Pasted text +5 lines]\n")
        drive(tmux, path, task, id)

      {:tmux_mock_out, "display-message" <> _} ->
        respond(tmux, "4242\n")
        drive(tmux, path, task, id)

      {:tmux_mock_out, _command} ->
        respond(tmux, "")
        drive(tmux, path, task, id)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    end
  end

  defp respond(tmux, body), do: send(GenServer.whereis(tmux), {:tmux_mock_data, "%begin 1 1 0\n#{body}%end 1 1 0\n"})
end
