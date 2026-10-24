defmodule Aiur.KeepAgentsRestartE2ETest do
  use ExUnit.Case, async: false
  import Aiur.TestSupport.EngineCase
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.TestCleanup
  alias Aiur.TestSupport.WorkflowFiles

  @moduletag :integration
  @tag timeout: 180_000
  test "four mid-turn providers survive the real engine restart and polling admits a fifth" do
    restart_case(false)
  end

  @tag timeout: 180_000
  test "an incompatible schema falls back for every agent and resumes their sessions" do
    restart_case(true)
  end

  defp restart_case(incompatible?) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    root = Aiur.TestSupport.tmp_root!("keep-agents-engine-#{nonce}")
    File.mkdir_p!(Path.join(root, "run"))
    endpoint = Path.join(System.tmp_dir!(), "k4-#{nonce}")
    {:ok, socket} = :gen_udp.open(0, [:binary, {:ifaddr, {:local, endpoint}}, {:active, true}])
    File.write!(Path.join(root, "endpoint"), endpoint)
    on_exit(fn -> File.rm(endpoint) end)

    File.write!(Path.join(root, "provider.py"), provider_script())
    File.write!(Path.join(root, "daemon.exs"), daemon_script())

    WorkflowFiles.write_workflow_file!(Path.join(root, "workflow.yaml"),
      tracker_kind: "memory",
      workspace_root: Path.join(root, "workspaces"),
      tracker_active_states: ["todo", "in-progress"],
      tracker_terminal_states: ["done"],
      poll_interval_seconds: 5,
      max_concurrent_agents: 5,
      max_turns: 1,
      codex_command: "python3 #{Path.join(root, "provider.py")} #{root}",
      hook_after_create: ~s(git -C "$PWD" init -q; echo ready > README.md; git -C "$PWD" add README.md; git -C "$PWD" -c user.name=Test -c user.email=test@example.test commit -qm fixture),
      pre_warmed_sessions: 0
    )

    workflow = Path.join(root, "workflow.yaml")
    File.write!(workflow, String.replace(File.read!(workflow), "agent:\n", "agent:\n  max_cpu_pressure: null\n  target_cpu_pressure: null\n"))
    release = fake_release()
    epmd = System.find_executable("epmd") || raise "epmd is required for the real restart fixture"
    epmd_bin = Path.join(release, "erts-0/bin")
    File.mkdir_p!(epmd_bin)
    File.ln_s!(epmd, Path.join(epmd_bin, "epmd"))

    paths = Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]))
    elixir = System.find_executable("elixir")
    fixture = Path.join(root, "daemon.exs")
    vm = Enum.map_join(paths, " ", &("-pa " <> quote_shell(Path.expand(&1))))

    boot = """
    #!/usr/bin/env bash
    cookie='' node=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cookie) shift; cookie="$1" ;;
        --name) shift; node="$1" ;;
      esac
      shift
    done
    export KEEP_AGENTS_ROOT=#{quote_shell(root)}
    export ERL_FLAGS='+S 2:2 +SDio 1 +SDcpu 1'
    exec #{quote_shell(elixir)} #{vm} --cookie "$cookie" --name "$node" #{quote_shell(fixture)}
    """

    rpc = """
    #!/usr/bin/env bash
    export ERL_FLAGS='+S 2:2 +SDio 1 +SDcpu 1'
    exec #{quote_shell(elixir)} --cookie "$RELEASE_COOKIE" --name "keep-agents-rpc-$$@127.0.0.1" --rpc-eval "$RELEASE_NODE" "$2"
    """

    for {file, body} <- [{Path.join(release, "releases/0.1.1/elixir"), boot}, {Path.join(release, "bin/aiur"), rpc}] do
      File.write!(file, body)
      File.chmod!(file, 0o755)
    end

    env = [
      {"USER", System.get_env("USER")},
      {"AIUR_COOKIE_FILE", Path.join(root, "cookie")},
      {"XDG_CONFIG_HOME", Path.join(root, "config")},
      {"AIUR_PROJECT_ROOT", nil},
      {"AIUR_PROJECT_ROOT_SOURCE", nil},
      {"AIUR_RELEASE_DIR", release},
      {"AIUR_BG_STATE_DIR", Path.join(root, "bg")},
      {"AIUR_REPO_ROOT", root},
      {"XDG_RUNTIME_DIR", Path.join(root, "run")},
      {"AIUR_INSTANCE_KEY", ""},
      {"AIUR_RELEASE_NODE", "aiur-keepagents-#{nonce}@127.0.0.1"},
      {"AIUR_RESTART_BUILD_CMD", nil},
      {"AIUR_SESSION_PREFIX", "keep-agents-test-#{nonce}"},
      {"AIUR_TMUX_GRACE_TICKS", "600"}
    ]

    on_exit(fn ->
      run_engine(["stop"], env)
      TestCleanup.rm_rf!(root)
    end)

    {boot_output, status} = run_engine(["--bg", "--no-dashboard"], env)
    assert status == 0, boot_output <> diagnostics(root)
    for _ <- 1..4, do: wait_event(socket, "mid_turn")
    before = agents(env)
    assert length(before) == 4

    identities =
      Map.new(before, fn agent ->
        assert {:ok, identity} = Aiur.ProcessIdentity.resolve(String.to_integer(agent["provider_pid"]))
        {agent["provider_pid"], identity}
      end)

    lifecycle_before = dispatch_events(root)
    assert Enum.sort(Enum.map(lifecycle_before, & &1["attributes"]["ticket"])) == ~w(1 2 3 4)
    tracker_before = read(Path.join(root, "tracker.log"))
    # Simulate a schema mismatch across the build gap using the production validator.
    {args, restart_env} =
      if incompatible? do
        script = "import json,pathlib;p=pathlib.Path(" <> inspect(Path.join(root, "runtime/handoff/current.json")) <> ");r=json.loads(p.read_text());r['handoff_schema']=99;p.write_text(json.dumps(r))"
        {["restart", "--keep-agents", "--no-dashboard"], env ++ [{"AIUR_RESTART_BUILD_CMD", "python3 -c " <> quote_shell(script)}, {"AIUR_RESTART_BUILD_VERIFIES", "0"}]}
      else
        {["restart", "--keep-agents", "--no-build", "--no-dashboard"], env}
      end

    {restart_output, status} = run_engine(args, restart_env)
    assert status == 0, restart_output <> diagnostics(root)
    report = json_command(["status", "--handoff", "--json"], env)

    if incompatible? do
      verify_fallback(root, env, socket, before, report, restart_output)
    else
      assert restart_output =~ "adopted=4 fallback=0"
      assert report["fallback"] == []
      assert length(report["adopted"]) == 4

      for agent <- before do
        adopted = Enum.find(report["adopted"], &(&1["identifier"] == agent["identifier"]))
        assert adopted["provider_pid_before"] == agent["provider_pid"]
        assert adopted["provider_pid_after"] == agent["provider_pid"]
        assert adopted["session_id_before"] == agent["session_id"]
        assert adopted["session_id_after"] == agent["session_id"]
        assert Aiur.ProcessIdentity.resolve(String.to_integer(agent["provider_pid"])) == {:ok, identities[agent["provider_pid"]]}, diagnostics(root)
      end

      # No lifecycle dispatch or tracker claim-release writes during adoption.
      assert dispatch_events(root) == lifecycle_before
      assert read(Path.join(root, "tracker.log")) == tracker_before
      complete_agents(env, root, socket, before)

      # Use the real periodic poll, without sending a forced poll message.
      {added_output, 0} =
        run_sourced_engine(
          """
          run_control_rpc 'added_at = System.system_time(:millisecond); Application.put_env(:aiur, :memory_tracker_issues, [%Aiur.Issue{id: "5", identifier: "5", title: "new ticket", state: "todo", selected_backend: "codex"}]); IO.puts("ADDED:" <> to_string(added_at)); Aiur.ControlCLI.Protocol.exit_marker(0)'
          """,
          env
        )

      [_, added_at] = Regex.run(~r/ADDED:(\d+)/, added_output)
      event = wait_dispatch(socket, "5")
      assert event["ticket"] == "5"
      assert event["timestamp_ms"] - String.to_integer(added_at) <= 5_000
    end
  end

  defp verify_fallback(root, env, socket, before, report, restart_output) do
    assert restart_output =~ "adopted=0 fallback=4"
    assert report["adopted"] == []
    assert Enum.map(report["fallback"], & &1["reason"]) == List.duplicate(":schema", 4)
    for _ <- 1..4, do: wait_event(socket, "mid_turn")
    after_fallback = agents(env)
    assert length(after_fallback) == 4

    for agent <- before do
      resumed = Enum.find(after_fallback, &(&1["identifier"] == agent["identifier"]))
      refute resumed["provider_pid"] == agent["provider_pid"]
      assert resumed["session_id"] == agent["session_id"]
      requests = root |> Path.join("thread-requests.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(
               requests,
               &(&1["method"] == "thread/resume" and to_string(&1["pid"]) == resumed["provider_pid"] and &1["thread_id"] == String.replace_suffix(agent["session_id"], "-turn-1", ""))
             )

      refute os_pid_alive?(agent["provider_pid"])
    end

    complete_agents(env, root, socket, after_fallback)
  end

  defp dispatch_events(root) do
    root |> Path.join("lifecycle.ndjson") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["attributes"]["event"] == "dispatch"))
  end

  defp agents(env), do: json_command(["agents", "--json"], env)["running"]

  defp json_command(args, env) do
    {output, status} = run_engine(args, env)
    assert status == 0, output
    output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "{")) |> Jason.decode!()
  end

  defp wait_event(socket, kind) do
    receive_barrier({:udp, ^socket, _address, _port, data})
    event = Jason.decode!(data)
    if event["event"] == kind, do: event, else: wait_event(socket, kind)
  end

  defp wait_dispatch(socket, ticket) do
    event = wait_event(socket, "dispatch")
    if event["ticket"] == ticket, do: event, else: wait_dispatch(socket, ticket)
  end

  defp complete_agents(env, root, socket, agents) do
    task =
      Task.async(fn ->
        run_sourced_engine(
          """
          AIUR_CONTROL_RPC_TIMEOUT_SECONDS=60 run_control_rpc '
            refs = for {_id, entry} <- :sys.get_state(Aiur.Orchestrator).running, do: Process.monitor(entry.pid)
            {:ok, socket} = :gen_udp.open(0, [:binary, {:ifaddr, {:local, <<>>}}])
            endpoint = File.read!(Path.join(System.fetch_env!("KEEP_AGENTS_ROOT"), "endpoint"))
            :ok = :gen_udp.send(socket, {:local, endpoint}, 0, Jason.encode!(%{event: "monitoring"}))
            :gen_udp.close(socket)
            for ref <- refs do
              receive do
                {:DOWN, ^ref, :process, _, :normal} -> :ok
                {:DOWN, ^ref, :process, _, reason} -> raise "runner failed: \#{inspect(reason)}"
              end
            end
            Aiur.ControlCLI.Protocol.exit_marker(0)'
          """,
          env
        )
      end)

    wait_event(socket, "monitoring")
    for agent <- agents, do: File.write!(Path.join(root, "complete-#{agent["provider_pid"]}"), "complete")
    {output, status} = Task.await(task, :infinity)
    assert status == 0, output

    for agent <- agents do
      assert read(Path.join([root, "workspaces", agent["identifier"], "logs", "agent.ndjson"])) =~ "turn_completed"
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, body} -> body
      _ -> ""
    end
  end

  defp diagnostics(root), do: "\n" <> read(Path.join(root, "daemon.log"))
  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp provider_script do
    ~S"""
    import json
    import os
    import pathlib
    import sys
    import threading
    import socket

    root = pathlib.Path(sys.argv[1])
    thread = 'thread-' + str(os.getpid())
    complete_fifo = root / ('complete-' + str(os.getpid()))
    os.mkfifo(complete_fifo)
    endpoint = (root / 'endpoint').read_text()
    events = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)

    def emit(frame):
        print(json.dumps(frame), flush=True)

    def complete():
        with complete_fifo.open() as release:
            release.read()
        emit({'method': 'turn/completed', 'params': {'turn': {'id': 'turn-1', 'status': 'completed'}}})

    for line in sys.stdin:
        frame = json.loads(line)
        method = frame.get('method')
        if 'id' not in frame:
            continue
        result = {}
        if method in ('thread/start', 'thread/resume'):
            requested = frame.get('params', {}).get('threadId')
            with (root / 'thread-requests.ndjson').open('a') as trace:
                trace.write(json.dumps({'pid': os.getpid(), 'method': method, 'thread_id': requested}) + '\n')
            if method == 'thread/resume':
                thread = requested
            result = {'thread': {'id': thread}}
        elif method == 'turn/start':
            result = {'turn': {'id': 'turn-1', 'status': 'inProgress'}}
        emit({'id': frame['id'], 'result': result})
        if method == 'turn/start':
            threading.Thread(target=complete, daemon=True).start()
            events.sendto(json.dumps({'event': 'mid_turn', 'pid': os.getpid()}).encode(), endpoint)
    """
  end

  defp daemon_script do
    ~S"""
    root = System.fetch_env!("KEEP_AGENTS_ROOT")
    launcher_env = Map.new(System.get_env(), fn {key, value} -> {key, value} end)
    config = Config.Reader.read!("config/config.exs", env: :test, target: :host)
    Application.put_all_env(config)
    for {key, value} <- launcher_env, do: System.put_env(key, value)

    for {key, leaf} <- [
          runtime_state_dir: "runtime",
          machine_state_dir: "machine",
          executor_state_dir: "executor",
          decision_state_dir: "decisions",
          repo_base_root: "repos",
          github_budget_dir: "budget",
          host_guard_bin_dir: "host/bin"
        ] do
      Application.put_env(:aiur, key, Path.join(root, leaf))
    end

    Application.put_env(:aiur, :log_file, Path.join(root, "daemon.log"))
    Application.put_env(:aiur, :no_dashboard, true)
    Application.put_env(:aiur, :cpu_pressure_source_override, fn -> {:ok, "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"} end)
    Application.put_env(:aiur, :orchestrator_initial_poll?, true)
    Application.put_env(:aiur, :process_reaper_registrations, true)
    workflow = Path.join(root, "workflow.yaml")
    Application.put_env(:aiur, :workflow_file_path, workflow)
    issues = for id <- 1..4, do: %Aiur.Issue{id: to_string(id), identifier: to_string(id), title: "Handoff #{id}", state: "todo", selected_backend: "codex"}
    Application.put_env(:aiur, :memory_tracker_issues, issues)
    Application.put_env(:aiur, :memory_tracker_recipient, self())

    {:ok, event_socket} = :gen_udp.open(0, [:binary, {:ifaddr, {:local, <<>>}}])
    endpoint = File.read!(Path.join(root, "endpoint"))
    Application.put_env(:aiur, :run_telemetry_lifecycle_recorder, fn kind, attrs, _opts ->
      File.write!(Path.join(root, "lifecycle.ndjson"), Jason.encode!(%{kind: kind, attributes: attrs}) <> "\n", [:append])
      if attrs.event == "dispatch" do
        :ok = :gen_udp.send(event_socket, {:local, endpoint}, 0, Jason.encode!(%{event: "dispatch", ticket: attrs.ticket, timestamp_ms: System.system_time(:millisecond)}))
      end
      :ok
    end)

    case Application.ensure_all_started(:aiur) do
      {:ok, _} -> :ok
      error -> raise "boot failed: #{inspect(error)}"
    end

    File.write!(Path.join(root, "booted"), System.pid())

    loop = fn loop ->
      receive do
        event ->
          File.write!(Path.join(root, "tracker.log"), inspect(event) <> "\n", [:append])
          loop.(loop)
      end
    end

    loop.(loop)
    """
  end
end
