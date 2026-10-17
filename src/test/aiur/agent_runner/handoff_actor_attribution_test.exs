defmodule Aiur.AgentRunner.HandoffActorAttributionTest do
  use Aiur.TestSupport

  import Aiur.Codex.TurnLoopTestSupport, only: [base_state: 0]
  alias Aiur.AgentRunner.Handoff
  alias Aiur.AppServer.{Adapter, RelayPort, Transport, TurnLoop}
  alias Aiur.Handoff.Fallback
  alias Aiur.ProcessReaper

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
end
