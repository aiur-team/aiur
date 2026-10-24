# Cohesion: both cases cover subprocess cleanup for the supervised restart lifecycle.
defmodule Aiur.Handoff.ApplicationRestartTest do
  use ExUnit.Case, async: false

  test "a timed out subprocess kills its complete process group" do
    shell = System.find_executable("sh")
    script = "sleep 300 & child=$!; group=$(ps -o pgid= -p $$ | tr -d ' '); printf '%s %s %s\\n' $$ $group $child; wait"

    provider = start_sleeping_group(shell)
    relay = start_sleeping_group(shell)
    runtime_root = Aiur.TestSupport.tmp_root!("handoff-timeout-provider")
    File.mkdir_p!(runtime_root)
    File.write!(Path.join(runtime_root, "provider-process-groups"), "#{elem(provider, 1)}\n#{elem(relay, 1)}\n")

    try do
      {:timeout, output, pid} =
        run_monitored_command(shell, ["-c", script], [], 250, fn -> kill_recorded_provider_groups(runtime_root) end)

      [shell_pid, group_id, child_pid] = output |> String.trim() |> String.split() |> Enum.map(&String.to_integer/1)

      assert shell_pid == pid
      assert group_id == pid
      refute process_running?(shell_pid)
      refute process_running?(child_pid)

      for {_port, group_pid, child_pid} <- [provider, relay] do
        refute process_running?(group_pid)
        refute process_running?(child_pid)
      end
    after
      for {port, group_pid, child_pid} <- [provider, relay] do
        kill_process_group(group_pid)
        Enum.each([group_pid, child_pid], &System.cmd("kill", ["-KILL", to_string(&1)], stderr_to_stdout: true))
        close_port(port)
      end

      Aiur.TestCleanup.rm_rf!(runtime_root)
    end
  end

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
      File.write!(
        Path.join(root, "provider-process-groups"),
        "#{metadata.pgid}\n#{metadata.relay_pid}\n"
      )
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

    try do
      case run_monitored_command(
             System.find_executable("elixir"),
             args,
             [
               {"ERL_FLAGS", "+S 2:2 +SDio 1 +SDcpu 1"},
               {"AIUR_HANDOFF_RUNTIME_ROOT", runtime_root}
             ],
             105_000,
             fn -> kill_recorded_provider_groups(runtime_root) end
           ) do
        {:timeout, captured, _pid} ->
          flunk("nested VM timed out; last output:\n#{captured}")

        {captured, status, _pid} ->
          assert status == 0, captured
          assert captured =~ "supervised-handoff-restart-ok"
      end
    after
      kill_recorded_provider_groups(runtime_root)
      Aiur.TestCleanup.rm_rf!(runtime_root)
    end
  end

  defp run_monitored_command(executable, args, env, timeout, on_timeout) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      case collect_output(port, "", deadline) do
        {:timeout, output} ->
          on_timeout.()
          kill_process_group(pid)
          {:timeout, output, pid}

        {output, status} ->
          {output, status, pid}
      end
    after
      kill_process_group(pid)
      close_port(port)
    end
  end

  defp collect_output(port, output, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, output}
    else
      receive do
        {^port, {:data, chunk}} -> collect_output(port, output <> chunk, deadline)
        {^port, {:exit_status, status}} -> {output, status}
      after
        remaining -> {:timeout, output}
      end
    end
  end

  defp kill_process_group(pid), do: System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)

  defp kill_recorded_provider_groups(runtime_root) do
    case File.read(Path.join(runtime_root, "provider-process-groups")) do
      {:ok, groups} ->
        groups
        |> String.split("\n", trim: true)
        |> Enum.each(&(String.to_integer(&1) |> kill_process_group()))

      {:error, :enoent} ->
        :ok
    end
  end

  defp start_sleeping_group(shell) do
    port =
      Port.open({:spawn_executable, String.to_charlist(shell)}, [
        :binary,
        :exit_status,
        args: [~c"-c", ~c"sleep 300 & child=$!; printf '%s\\n' $child; wait"]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    child_pid =
      receive do
        {^port, {:data, child}} -> child |> String.trim() |> String.to_integer()
      after
        5_000 -> flunk("process group fixture did not start")
      end

    {port, pid, child_pid}
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      _ -> false
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
