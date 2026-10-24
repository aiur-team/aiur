defmodule Aiur.Handoff.ApplicationRestartTest do
  use ExUnit.Case, async: false

  @tag timeout: 120_000
  test "a real supervised app restart adopts the relay turn without redispatch" do
    runtime_root = Aiur.TestSupport.tmp_root!("handoff-restart")

    script = ~S"""
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    Application.put_env(:aiur, :runtime_state_dir, System.fetch_env!("AIUR_HANDOFF_RUNTIME_ROOT"))
    Application.put_env(:aiur, :no_dashboard, true)
    phase = fn label -> IO.write(:stderr, "phase:#{label}\n") end
    boot = fn label ->
      phase.("#{label}-starting")
      case Application.ensure_all_started(:aiur) do
        {:ok, _} -> phase.("#{label}-ready")
        error ->
          IO.puts(File.read!(Application.fetch_env!(:aiur, :log_file)))
          raise "#{label}: #{inspect(error)}"
      end
    end
    boot.("first-boot")
    root = Application.fetch_env!(:aiur, :runtime_state_dir)
    workspace = Path.join(root, "restart-workspace")
    File.mkdir_p!(workspace)
    fifo = Path.join(root, "complete-turn")
    {_, 0} = System.cmd("mkfifo", [fifo])
    provider = Path.join(root, "provider.py")
    File.write!(provider, "import sys,json\nwith open(sys.argv[1]) as f: f.read()\nprint(json.dumps({'method':'turn/completed','params':{'turn':{'id':'turn-1','status':'completed'}}}),flush=True)\nsys.stdin.read()\n")
    issue = %Aiur.Issue{id: "3844", identifier: "3844", title: "restart", state: "in-progress"}
    owner = self()
    {:ok, old_runner} = Task.Supervisor.start_child(Aiur.TaskSupervisor, fn ->
      {:ok, lease} = Aiur.Workspace.Ownership.claim(issue.identifier)
      {:ok, lock} = Aiur.Workspace.HostLock.acquire(workspace, issue.identifier)
      :ok = Aiur.Workspace.Ownership.track_host_lock(lease, lock)
      {:ok, _lease} = Aiur.Workspace.Ownership.activate(lease)
      {:ok, port} = Aiur.AppServer.Adapter.start_port(workspace, "python3 " <> provider <> " " <> fifo)
      metadata = Aiur.AppServer.Transport.metadata(port)
      :ok = Aiur.Workspace.Ownership.track_provider(lease, %{root_pid: metadata.provider_pid, process_group_id: metadata.pgid})
      session = %{backend: "codex", port: port, thread_id: "restart-thread", workspace: workspace,
        metadata: %{}, auto_approve_requests: false, worker_host: nil}
      :ok = Aiur.AgentRunner.SessionResume.persist_session_handle(session, issue.identifier, nil)
      context = %{issue: issue, workspace: workspace, opts: [], turn_number: 1, max_turns: 1, prompt: "continue"}
      Aiur.AgentRunner.Handoff.before_turn(session, context)
      state = %{on_message: fn _ -> :ok end, on_safe_checkpoint: fn _ -> :noop end,
        tool_executor: fn _, _ -> %{"success" => true} end, auto_approve_requests: false,
        pending_operator_requests: %{}, outstanding_turns: 1, pending_interrupt_request_id: nil,
        interrupt_action: nil, pause_request_id: nil, current_turn_id: "turn-1", issue_identifier: "3844",
        turn_started?: false, active_turn_ids: MapSet.new(["turn-1"]), accepted_turn_ids: MapSet.new(),
        retired_turn_ids: MapSet.new(), anonymous_completion_consumed?: false,
        interrupt_acknowledged?: false, interrupt_idle_seen?: false, backend: Aiur.Codex.CodingAgent,
        timeout_ms: 60_000, pending_line: ""}
      send(owner, {:ready, self(), metadata})
      Aiur.AppServer.TurnLoop.receive_loop(session, state)
    end)
    metadata = receive do {:ready, ^old_runner, value} -> value after 15_000 -> raise "phase:runner-start timed out" end
    phase.("runner-ready")
    :sys.replace_state(Aiur.Orchestrator, fn state ->
      entry = %{pid: old_runner, ref: Process.monitor(old_runner), issue: issue, identifier: issue.identifier,
        started_at: DateTime.utc_now(), session_id: "restart-thread-turn-1", backend: "codex",
        agent_input_tokens: 0, agent_output_tokens: 0, agent_total_tokens: 0}
      %{state | running: %{"3844" => entry}, claimed: MapSet.new(["3844"])}
    end)
    before = :sys.get_state(Aiur.Orchestrator)
    {:ok, original_lifetime} = Aiur.DispatchBudgetStore.lifetime(issue.id)
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    phase.("handoff-prepare")
    {:ok, _handoff} = Aiur.Handoff.prepare()
    phase.("handoff-prepared")
    :ok = Application.stop(:aiur)
    phase.("first-app-stopped")
    true = Aiur.ProcessTree.process_alive?(metadata.provider_pid)
    # Trace the production dispatch telemetry emitter before any second-boot
    # process exists; VM tracing survives the Exchange and its bindings dying.
    Code.ensure_loaded!(Aiur.Orchestrator.TelemetryCohort)
    1 = :erlang.trace_pattern({Aiur.Orchestrator.TelemetryCohort, :record_dispatch, 3}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, self()}])
    boot.("second-boot")
    phase.("second-boot-adoption-check")
    after_boot = :sys.get_state(Aiur.Orchestrator)
    adopted = Map.fetch!(after_boot.running, "3844")
    true = is_binary(adopted.adopted_from)
    false = adopted.pid == old_runner
    true = before.dispatch_recovery == after_boot.dispatch_recovery
    {:ok, ^original_lifetime} = Aiur.DispatchBudgetStore.lifetime(issue.id)
    receive do
      {:memory_tracker_comment, _, _} -> raise "adoption posted a new claim comment"
      {:memory_tracker_state_update, _, _} -> raise "adoption changed tracker state"
    after
      0 -> :ok
    end
    ref = Process.monitor(adopted.pid)
    phase.("provider-released")
    File.write!(fifo, "complete")
    receive do
      {:DOWN, ^ref, :process, _, :normal} -> :ok
      {:DOWN, ^ref, :process, _, reason} -> raise "adopted runner failed: #{inspect(reason)}"
    after
      15_000 -> raise "phase:adopted-turn-finish timed out"
    end
    {:ok, %{thread_id: "restart-thread"}} = Aiur.SessionHandle.load("3844", "codex")
    true = String.contains?(File.read!(Path.join(workspace, "logs/agent.ndjson")), "turn_completed")
    {:ok, consumed} = Aiur.JsonStore.read(Aiur.Handoff.Record.path() <> ".consumed")
    [%{"status" => "adopted"}] = consumed["outcome"]
    delivered = :erlang.trace_delivered(:all)
    receive do
      {:trace_delivered, :all, ^delivered} -> :ok
    after
      5_000 -> raise "dispatch observation did not drain"
    end
    receive do
      {:trace, _, :call, {Aiur.Orchestrator.TelemetryCohort, :record_dispatch, [%Aiur.Issue{id: "3844"}, _, _]}} ->
        raise "adoption emitted dispatch telemetry for ticket 3844"
    after
      0 -> :ok
    end
    :erlang.trace(:new, false, [:call])
    :erlang.trace_pattern({Aiur.Orchestrator.TelemetryCohort, :record_dispatch, 3}, false, [:local])
    :ok = Application.stop(:aiur)
    phase.("complete")
    IO.puts("supervised-handoff-restart-ok")
    """

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", script]

    port =
      Port.open({:spawn_executable, String.to_charlist(System.find_executable("setsid"))}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [System.find_executable("elixir") | args],
        env: [
          {~c"ERL_FLAGS", ~c"+S 2:2 +SDio 1 +SDcpu 1"},
          {~c"AIUR_HANDOFF_RUNTIME_ROOT", String.to_charlist(runtime_root)}
        ]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      case collect_output(port, "", 105_000) do
        {:timeout, captured} ->
          System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
          close_port(port)
          flunk("nested VM timed out; last output:\n#{captured}")

        {captured, status} ->
          assert status == 0, captured
          assert captured =~ "supervised-handoff-restart-ok"
      end
    after
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      close_port(port)

      Aiur.TestCleanup.rm_rf!(runtime_root)
    end
  end

  defp collect_output(port, output, timeout) do
    receive do
      {^port, {:data, chunk}} ->
        next = output <> chunk
        collect_output(port, next, timeout)

      {^port, {:exit_status, status}} ->
        {output, status}
    after
      timeout -> {:timeout, output}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
