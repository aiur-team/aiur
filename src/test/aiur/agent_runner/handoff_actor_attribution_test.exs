defmodule Aiur.AgentRunner.HandoffActorAttributionTest do
  use Aiur.TestSupport

  import Aiur.Codex.TurnLoopTestSupport, only: [base_state: 0]
  alias Aiur.AgentRunner.Handoff
  alias Aiur.AppServer.{Adapter, RelayPort, Transport, TurnLoop}
  alias Aiur.Handoff.Fallback
  alias Aiur.{ProcessReaper, Tmux}

  setup do
    previous = Application.get_env(:aiur, :process_reaper_registrations)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    # Shutdown tests leave the daemon registry draining; own a fresh real registry.
    original = Process.whereis(ProcessReaper)
    if original, do: Process.unregister(ProcessReaper)
    reaper = start_supervised!(ProcessReaper)

    on_exit(fn ->
      if Process.alive?(reaper), do: GenServer.stop(reaper)
      if original && Process.alive?(original), do: Process.register(original, ProcessReaper)
      Application.put_env(:aiur, :process_reaper_registrations, previous)
    end)
  end

  # Run telemetry only samples registry roots that carry a ticket; an adopted
  # relay registered without one left analytics at 0 concurrency (#4829).
  @tag :tmp_dir
  test "an adopted relay registers its root under the ticket it is working", %{tmp_dir: workspace} do
    script = Path.join(workspace, "provider.py")
    File.write!(script, "import time\ntime.sleep(10)\n")
    parent = self()

    runner =
      spawn(fn ->
        {:ok, port} = Adapter.start_port(workspace, "python3 #{script}")
        session = %{backend: "codex", port: port, thread_id: "thread-1", workspace: workspace}
        context = %{issue: %Aiur.Issue{id: "1", identifier: "4811"}, workspace: workspace, opts: [], turn_number: 1, max_turns: 1}
        Handoff.before_turn(session, context)
        send(parent, {:ready, self()})
        TurnLoop.receive_loop(session, Map.merge(base_state(), %{timeout_ms: 5_000, pending_line: ""}))
      end)

    assert_receive {:ready, ^runner}, 5_000
    Handoff.hold(runner)
    assert {:ok, record} = Handoff.snapshot(runner)
    on_exit(fn -> Fallback.stop(record) end)
    Process.exit(runner, :kill)

    assert {:ok, session} = Handoff.attach(record, record["transport"]["generation"] + 1)
    on_exit(fn -> if Process.alive?(session.port), do: Transport.close(session.port) end)
    relay_pid = RelayPort.call(session.port, :metadata).relay_pid

    assert Enum.any?(ProcessReaper.entries(), fn
             {{:os_pid, ^relay_pid}, :agent, %{comm: "agent_relay.py", ticket: "4811", backend: "codex", remote: false}} -> true
             _entry -> false
           end)
  end

  test "an adopted Claude REPL registers its root under the ticket it is working" do
    # Adoption renames the pane through the daemon's Tmux; stand a mock in its place.
    original = Process.whereis(Tmux)
    if original, do: Process.unregister(Tmux)
    tmux = start_supervised!({Tmux, [transport: {:mock, self()}, name: Tmux, session: "test"]})
    on_exit(fn -> if original && Process.alive?(original), do: Process.register(original, Tmux) end)

    session = %{backend: "claude-repl", pane_id: "%50", os_pid: 4242, identifier: "4812"}

    record = %{
      "backend" => "claude-repl",
      "transport" => %{"kind" => "repl", "socket" => "aiur-test"},
      "session_state" => Handoff.encode(session),
      "turn_context" => Handoff.encode(%{issue: %Aiur.Issue{id: "2", identifier: "4812"}}),
      "queued_frames" => Handoff.encode([])
    }

    # The first decode loads every app module; keep that out of the mock's reply window.
    Handoff.decode(record["queued_frames"])
    attach = Task.async(fn -> Handoff.attach(record, 2) end)
    assert {:ok, _session} = answer_tmux(tmux, attach)

    assert Enum.any?(ProcessReaper.entries(), fn
             {{:os_pid, 4242}, :agent, %{comm: "claude", ticket: "4812", backend: "claude-repl"}} -> true
             _entry -> false
           end)
  end

  # Answer every command the mock sees (daemon processes may share it) until the task returns.
  defp answer_tmux(tmux, task) do
    receive do
      {:tmux_mock_out, _command} ->
        send(tmux, {:tmux_mock_data, "%begin 1 1 0\n%end 1 1 0\n"})
        answer_tmux(tmux, task)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    after
      10_000 -> flunk("Handoff.attach never returned")
    end
  end
end
