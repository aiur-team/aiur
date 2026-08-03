defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @pgrep_skip_reason Aiur.TestSupport.pgrep_skip_reason()

  # Run the engine's `__identity` probe with a clean AIUR_* env plus the given
  # overrides, returning the resolved KEY=VALUE map.
  defp identity(overrides) do
    base = [
      {"USER", "tester"},
      {"AIUR_BG_STATE_DIR", nil},
      {"AIUR_SESSION_PREFIX", nil},
      {"AIUR_PROFILES_FILE", nil},
      {"AIUR_RELEASE_NODE", nil},
      {"AIUR_COOKIE_FILE", nil},
      {"AIUR_RELEASE_DIR", nil},
      {"AIUR_REPO_ROOT", nil},
      {"AIUR_INSTANCE_KEY", nil}
    ]

    env = base ++ overrides

    {out, 0} = System.cmd(@engine, ["__identity"], env: env, stderr_to_stdout: true)

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  test "resolves a per-instance keyed identity" do
    # Runs inside an aiur project (this repo has .aiur/config), so the node name is
    # keyed by the project root — two instances for the same user can't collide (#431).
    id = identity([])

    assert id["AIUR_SESSION_PREFIX"] == "aiur"
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
    assert id["AIUR_INSTANCE_KEY"] =~ ~r/\A[0-9a-f]{1,12}\z/
    assert id["AIUR_BG_STATE_DIR"] =~ ~r{/\.config/aiur$}
    assert id["AIUR_COOKIE_FILE"] =~ ~r{/\.config/aiur/cookie$}
  end

  test "the state dir is redirectable so tests need not touch ~/.config/aiur" do
    id = identity([{"AIUR_BG_STATE_DIR", "/tmp/aiur-test-state"}])

    assert id["AIUR_BG_STATE_DIR"] == "/tmp/aiur-test-state"
    assert id["AIUR_COOKIE_FILE"] == "/tmp/aiur-test-state/cookie"
    # the instance key is derived from the project root, not the state dir
    assert id["AIUR_RELEASE_NODE"] =~ ~r/\Aaiur-tester-[0-9a-f]{1,12}@127\.0\.0\.1\z/
  end

  test "tmux pane launcher preserves agent-local opencode bridge port override" do
    assert File.read!(@engine) =~ "AIUR_OPENCODE_BRIDGE_PORT"
  end

  test "engine exports the effective soft nofile limit after raising it" do
    {out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_NOFILE_SOFT_LIMIT" = "$(ulimit -Sn)" && echo NOFILE_MATCH|,
        [{"AIUR_NOFILE_SOFT_LIMIT", "1"}]
      )

    assert out =~ "NOFILE_MATCH"
  end

  test "engine captures a best-effort operator pid and preserves an explicit root" do
    {out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_OPERATOR_PID" = "$PPID" && echo PARENT_MATCH|,
        [{"AIUR_OPERATOR_PID", "invalid"}]
      )

    assert out =~ "PARENT_MATCH"

    {override_out, 0} =
      run_sourced_engine(
        ~S|test "$AIUR_OPERATOR_PID" = "4242" && echo OVERRIDE_KEPT|,
        [{"AIUR_OPERATOR_PID", "4242"}]
      )

    assert override_out =~ "OVERRIDE_KEPT"
  end

  test "tmux pane launcher re-exports resource attribution inputs" do
    engine = File.read!(@engine)

    assert engine =~
             "AIUR_OPERATOR_PID AIUR_NOFILE_SOFT_LIMIT ERL_CRASH_DUMP ERL_CRASH_DUMP_SECONDS"
  end

  test "sourced-engine runs isolate the node identity so reaps can't hit a live host node" do
    # The engine's launch/stop paths reap any BEAM holding their node name
    # (`kill_beams_matching "-name $AIUR_RELEASE_NODE"`). When `mix test` sources
    # the engine on the same host/project as a live aiur, an un-isolated run
    # resolves the SAME node name and reaps the operator's BEAM mid-run. Guard:
    # sourced-engine runs must resolve a unique node, never the host's real one.
    {real, 0} =
      System.cmd(@engine, ["__identity"], env: [{"AIUR_ENGINE", @engine}], stderr_to_stdout: true)

    real_node =
      real
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case String.split(line, "=", parts: 2) do
          ["AIUR_RELEASE_NODE", v] -> v
          _ -> nil
        end
      end)

    {sourced, 0} =
      run_sourced_engine(~s|aiur_resolve_identity; printf '%s' "$AIUR_RELEASE_NODE"|, [])

    refute sourced == real_node
    assert sourced =~ ~r/\Aaiur-enginetest-\d+@127\.0\.0\.1\z/
  end

  # A minimal stub release: start_erl.data + a fake `elixir` that echoes its args
  # so dispatch/boot-shape can be asserted without a real BEAM.
  defp fake_release do
    dir = Path.join(System.tmp_dir!(), "aiur-engine-rel-#{System.unique_integer([:positive])}")
    vsn = Path.join([dir, "releases", "0.1.1"])
    File.mkdir_p!(vsn)
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join([dir, "releases", "start_erl.data"]), "16.4 0.1.1\n")
    elixir = Path.join(vsn, "elixir")
    File.write!(elixir, "#!/usr/bin/env bash\necho \"ELIXIR_ARGS: $*\"\n")
    File.chmod!(elixir, 0o755)
    for f <- ["sys", "start_clean", "vm.args"], do: File.write!(Path.join(vsn, f), "")
    File.write!(Path.join([dir, "bin", "aiur"]), "#!/usr/bin/env bash\necho \"BIN: $*\"\n")
    File.chmod!(Path.join([dir, "bin", "aiur"]), 0o755)
    dir
  end

  defp run_engine(args, env) do
    System.cmd(@engine, args, env: [{"USER", "tester"} | env], stderr_to_stdout: true)
  end

  test "every help alias prints usage and exits 0" do
    for flag <- ["help", "-h", "-help", "--h", "--help"] do
      {out, code} = run_engine([flag], [])
      assert code == 0, "#{flag} should exit 0"
      assert out =~ "Usage: aiur", "#{flag} should print usage"
    end
  end

  test "usage describes init and no longer lists sweep" do
    {out, 0} = run_engine(["--help"], [])
    assert out =~ ~r/aiur init \[--force\]\s+scaffold/
    assert out =~ "aiur --todo <ids...> [--only]"
    assert out =~ "aiur findings [--unfiled] [--slugs] [--scope aiur|repo]"
    assert out =~ "aiur findings --record <json> --repo <owner/repo>"
    assert out =~ "aiur findings --digest [--scope aiur|repo]"
    assert out =~ "aiur run [--bg] [--no-dashboard] [--debug]"
    assert out =~ "aiur --bg [--no-dashboard] [--debug]"
    refute out =~ "sweep"
  end

  test "an incomplete dev release returns the retryable control code" do
    rel = fake_release()
    state = tmp_state()
    signal = Path.join(System.tmp_dir!(), "aiur-control-retry-#{System.unique_integer([:positive])}")
    File.rm!(Path.join([rel, "releases", "0.1.1", "elixir"]))

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(signal)
    end)

    {out, 0} =
      run_sourced_engine(
        ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
        [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_CONTROL_RELEASE_RETRYABLE", "1"},
          {"AIUR_CONTROL_RELEASE_RETRY_SIGNAL", signal}
        ]
      )

    assert out =~ "CODE=75"
    assert File.exists?(signal)
    refute out =~ "release elixir launcher not found"
  end

  test "an rpc launcher removed by an overwrite returns the retryable control code" do
    rel = fake_release()
    state = tmp_state()
    signal = Path.join(System.tmp_dir!(), "aiur-control-retry-#{System.unique_integer([:positive])}")
    release_bin = Path.join([rel, "bin", "aiur"])

    File.write!(release_bin, "#!/usr/bin/env bash\nrm -f \"$0\" \"#{rel}/releases/0.1.1/elixir\"\nexit 42\n")
    File.chmod!(release_bin, 0o755)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(signal)
    end)

    {out, 0} =
      run_sourced_engine(
        ~s|if run_control_rpc "Aiur.AgentControlCLI.status()"; then code=0; else code=$?; fi; echo "CODE=$code"|,
        [
          {"AIUR_RELEASE_DIR", rel},
          {"AIUR_BG_STATE_DIR", state},
          {"AIUR_CONTROL_RELEASE_RETRYABLE", "1"},
          {"AIUR_CONTROL_RELEASE_RETRY_SIGNAL", signal}
        ]
      )

    assert out =~ "CODE=75"
    assert File.exists?(signal)
    refute out =~ "rpc to"
  end

  test "--bg controls detachment independently from --no-dashboard" do
    script = """
    run_session() {
      local mode="$1"
      shift
      printf 'MODE=%s ARGS=%s\\n' "$mode" "$*"
    }
    aiur_engine_main run --bg --no-dashboard --debug
    aiur_engine_main --bg --no-dashboard --debug
    aiur_engine_main run --no-dashboard --bg --debug
    aiur_engine_main --no-dashboard --bg --debug
    aiur_engine_main run --no-dashboard
    aiur_engine_main --no-dashboard
    """

    {out, 0} = run_sourced_engine(script, [])

    assert String.split(out, "\n", trim: true) == [
             "MODE=background ARGS=--no-dashboard --debug",
             "MODE=background ARGS=--no-dashboard --debug",
             "MODE=background ARGS=--no-dashboard --debug",
             "MODE=background ARGS=--no-dashboard --debug",
             "MODE=foreground ARGS=--no-dashboard",
             "MODE=foreground ARGS=--no-dashboard"
           ]
  end

  test "run argv keeps dashboard suppression independent from headless mode" do
    script = """
    print_run_argv() {
      local mode="$1"
      shift
      build_run_argv "$mode" "$@"
      printf '%s|' "${run_argv[@]}"
      printf '\n'
    }
    print_run_argv background --host 127.0.0.1
    print_run_argv background --no-dashboard
    print_run_argv foreground --no-dashboard
    """

    {out, 0} = run_sourced_engine(script, [])

    [background, lean_background, foreground] = String.split(out, "\n", trim: true)

    assert background =~ "--headless|"
    refute background =~ "--no-dashboard|"
    assert lean_background =~ "--headless|"
    assert lean_background =~ "--no-dashboard|"
    assert foreground =~ "--interactive|"
    assert foreground =~ "--no-dashboard|"
    refute foreground =~ "--headless|"
  end

  test "background dashboard status reports a bound URL, explicit suppression, or listener refusal" do
    script = """
    probe_dashboard_url() { printf '%s' "$PROBE_URL"; }
    print_background_dashboard_status 0 /tmp/boot.log
    PROBE_URL=""
    print_background_dashboard_status 1 /tmp/boot.log
    print_background_dashboard_status 0 /tmp/boot.log
    """

    {out, 0} = run_sourced_engine(script, [{"PROBE_URL", "http://127.0.0.1:4567"}])

    assert out =~ "Dashboard: http://127.0.0.1:4567"
    assert out =~ "Dashboard disabled by --no-dashboard."
    assert out =~ "dashboard listener unavailable; inspect /tmp/boot.log"
  end

  test "--version is distribution-free so it never collides with a running node" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["--version"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    # Runs through the start_clean `elixir --eval` path (like init), never the
    # distributed release start script — so it claims no node name.
    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "--eval"
    refute out =~ "--name"
    refute out =~ "BIN:"
  end

  @tag skip: @pgrep_skip_reason
  test "kill_beams_matching reaps a node-name holder from any release dir" do
    # A unified node name means an orphaned BEAM from a different release dir
    # still blocks a launch; the reaper must match by `-name`, not release path.
    marker = "-name aiur-killtest-#{System.unique_integer([:positive])}@127.0.0.1"
    on_exit(fn -> System.cmd("pkill", ["-f", marker], stderr_to_stdout: true) end)

    # Run from a file so the marker isn't in the launching shell's own argv
    # (which `pgrep -f` would otherwise match and reap).
    script = """
    source #{@engine}
    set +e
    bash -c 'exec -a "beam.smp #{marker} extra" sleep 10' >/dev/null 2>&1 &
    seen=0
    for _ in $(seq 1 20); do
      pgrep_out="$(pgrep -f -- '#{marker}' 2>&1)"
      pgrep_status=$?
      case "$pgrep_status" in
        0) seen=1; break ;;
        1)
          if [ -n "$pgrep_out" ]; then
            printf 'PGREP_ERROR: %s\\n' "$pgrep_out"
            break
          fi
          ;;
        *) printf 'PGREP_ERROR: %s\\n' "$pgrep_out"; break ;;
      esac
      sleep 0.1
    done
    if [ "$seen" -ne 1 ]; then
      echo SETUP_FAILED
    else
      kill_beams_matching '#{marker}'
    fi
    pgrep_out="$(pgrep -f -- '#{marker}' 2>&1)"
    pgrep_status=$?
    case "$pgrep_status" in
      0) echo STILL_ALIVE ;;
      1)
        if [ -n "$pgrep_out" ]; then
          printf 'PGREP_ERROR: %s\\n' "$pgrep_out"
        else
          echo REAPED
        fi
        ;;
      *) printf 'PGREP_ERROR: %s\\n' "$pgrep_out" ;;
    esac
    """

    path = Path.join(System.tmp_dir!(), "aiur-reap-#{System.unique_integer([:positive])}.sh")
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    {out, _} = System.cmd("bash", [path], stderr_to_stdout: true)
    refute out =~ "PGREP_ERROR"
    refute out =~ "SETUP_FAILED"
    assert out =~ "REAPED"
  end

  test "workspace cwd sweep reaps only descendants of a non-shallow root" do
    if File.dir?("/proc") do
      root = Path.join(System.tmp_dir!(), "aiur-cwd-reap-#{System.unique_integer([:positive])}")
      inside = Path.join(root, "repo/468")
      outside = Path.join(System.tmp_dir!(), "aiur-cwd-spared-#{System.unique_integer([:positive])}")
      File.mkdir_p!(inside)
      File.mkdir_p!(outside)

      inside_pid = spawn_sleeper(inside)
      outside_pid = spawn_sleeper(outside)

      on_exit(fn ->
        kill_pid(inside_pid)
        kill_pid(outside_pid)
        File.rm_rf(root)
        File.rm_rf(outside)
      end)

      {out, 0} =
        run_sourced_engine(
          """
          AIUR_WORKSPACE_REAP_SWEEPS=2 reap_workspace_cwd_agents "$ROOT"
          AIUR_WORKSPACE_REAP_SWEEPS=2 reap_workspace_cwd_agents /tmp
          """,
          [{"ROOT", root}]
        )

      assert out =~ "refusing shallow workspace cwd sweep root: /tmp"
      assert wait_dead(inside_pid), "expected the workspace-rooted process to be reaped"
      assert os_pid_alive?(outside_pid), "expected the out-of-root process to survive"
    end
  end

  test "workspace root handoff comes from the instance record" do
    script = """
    aiur_instance_record_path() { printf '%s' "$RECORD"; }
    workspace_root_file_from_instance_record
    """

    record = Path.join(System.tmp_dir!(), "aiur-workspace-record-#{System.unique_integer([:positive])}")
    root_file = Path.join(System.tmp_dir!(), "aiur-workspace-root-#{System.unique_integer([:positive])}")

    File.write!(
      record,
      """
      AIUR_RECORD_NODE=aiur-test@127.0.0.1
      AIUR_RECORD_SESSION=aiur-test-default
      AIUR_RECORD_SOCKET=aiur-test
      AIUR_RECORD_PROJECT_ROOT=/tmp/aiur-project
      AIUR_RECORD_WORKSPACE_ROOT_FILE=#{inspect(root_file)}
      """
    )

    on_exit(fn -> File.rm(record) end)

    {out, 0} = run_sourced_engine(script, [{"RECORD", record}])

    assert String.trim(out) == root_file
  end

  test "load_dotenv reads ./.env, strips quotes, and lets shell exports win" do
    dir = Path.join(System.tmp_dir!(), "aiur-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "# token\nGITHUB_TOKEN=fromfile\nFOO=\"bar baz\"\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src = "cd #{dir}; source #{@engine}; load_dotenv; echo \"TOK=$GITHUB_TOKEN|FOO=$FOO\""

    {out, 0} =
      System.cmd("bash", ["-c", src],
        env: [{"GITHUB_TOKEN", nil}, {"FOO", nil}],
        stderr_to_stdout: true
      )

    assert out =~ "TOK=fromfile|FOO=bar baz"

    # A value already in the environment is never clobbered by the file.
    {out2, 0} = System.cmd("bash", ["-c", "export GITHUB_TOKEN=shell; #{src}"], stderr_to_stdout: true)
    assert out2 =~ "TOK=shell|"
  end

  test "run-only environment scrub removes the operator readiness token" do
    dir = Path.join(System.tmp_dir!(), "aiur-readiness-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".env"), "AIUR_CI_READINESS_TOKEN=operator-only\n")
    on_exit(fn -> File.rm_rf!(dir) end)

    src =
      "cd #{dir}; source #{@engine}; load_dotenv; " <>
        "printf 'LOADED=%s|' \"$AIUR_CI_READINESS_TOKEN\"; " <>
        "scrub_run_only_env; printf 'RUN=%s' \"${AIUR_CI_READINESS_TOKEN-unset}\""

    {out, 0} =
      System.cmd("bash", ["-c", src],
        env: [{"AIUR_CI_READINESS_TOKEN", nil}],
        stderr_to_stdout: true
      )

    assert out =~ "LOADED=operator-only|RUN=unset"

    engine = File.read!(@engine)
    assert engine =~ ~r/load_dotenv\s+scrub_run_only_env/
    assert engine =~ "printf 'unset AIUR_CI_READINESS_TOKEN\\n'"
  end

  test "init intentionally retains the operator readiness token" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-init-token-#{System.unique_integer([:positive])}")
    elixir = Path.join([rel, "releases", "0.1.1", "elixir"])

    File.write!(elixir, "#!/usr/bin/env bash\nprintf 'CI_TOKEN=%s\\n' \"${AIUR_CI_READINESS_TOKEN-unset}\"\n")

    on_exit(fn ->
      File.rm_rf!(rel)
      File.rm_rf!(state)
    end)

    {out, 0} =
      run_engine(["init"], [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_CI_READINESS_TOKEN", "operator-only"}
      ])

    assert out =~ "CI_TOKEN=operator-only"
  end

  test "an unknown command exits 64 with usage" do
    {out, code} = run_engine(["bogus-not-a-path"], [])
    assert code == 64
    assert out =~ "unknown command"
  end

  test "init boots interactively and distribution-free (no --name/--cookie)" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["init"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "--eval"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "--cookie"
  end

  test "todo routes through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\nrun_todo --todo 11 012,13 --only|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.todo([\"11\", \"12\", \"13\"], only: true, emit_exit_marker: true)"
  end

  test "todo control rpc propagates live success and semantic failure codes" do
    for {rpc_output, expected_code} <- [
          {"queued 1 ticket(s); cleared 0 other(s)\n__AIUR_CONTROL_EXIT__:0", 0},
          {"queued 0 ticket(s); cleared 0 other(s)\n__AIUR_CONTROL_EXIT__:1", 1}
        ] do
      script = """
      resolve_release() { release_bin="/bin/true"; release_dir="/tmp"; vsn_dir="/tmp"; RELEASE_NODE="aiur-test@127.0.0.1"; }
      prepare_distribution() { :; }
      resolve_control_identity_from_records() { :; }
      probe_node_liveness() { printf up; }
      run_release_rpc_with_timeout() {
        AIUR_CONTROL_RPC_OUTPUT='#{rpc_output}'
        AIUR_CONTROL_RPC_TIMED_OUT=0
        return 0
      }
      code=0
      run_todo --todo 123 || code=$?
      echo "CODE=$code"
      """

      {out, 0} = run_sourced_engine(script, [])

      assert out =~ "CODE=#{expected_code}"
      assert out =~ "queued"
      refute out =~ "returned no exit marker"
    end
  end

  test "streaming control rpc reports a stopped daemon" do
    rel = fake_release()
    state = tmp_state()

    {out, 1} =
      run_sourced_engine(
        ~S|resolve_release() { release_bin="/bin/false"; RELEASE_NODE="aiur-test@127.0.0.1"; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf down; }; run_control_stream 'Aiur.AgentControlCLI.executor_listen()'|,
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}]
      )

    assert out =~ "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry."
    refute out =~ "GenServer"
  end

  test "streaming control rpc preserves an unexpected crash marker" do
    marker = Path.join(System.tmp_dir!(), "aiur-stream-crash-#{System.unique_integer([:positive])}")
    File.write!(marker, "reason=boom\n")

    {out, 1} =
      run_sourced_engine(
        ~S|resolve_release() { release_bin="/bin/false"; RELEASE_NODE="aiur-test@127.0.0.1"; }; prepare_distribution() { :; }; resolve_control_identity_from_records() { :; }; probe_node_liveness() { printf down; }; aiur_crash_marker_path() { printf '%s' "$CRASH_MARKER"; }; run_control_stream 'Aiur.AgentControlCLI.executor_listen()'|,
        [{"CRASH_MARKER", marker}]
      )

    assert out =~ "aiur: background daemon"
    assert out =~ "reason=boom"
    refute out =~ "error: aiur is not running"
  end

  test "findings boots distribution-free without requiring a running node" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["findings", "--slugs"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "Aiur.CLI.main(Aiur.CLI.argv_from_file())"
    refute out =~ "--name"
    refute out =~ "BIN:"
  end

  test "todo without IDs exits 64 before resolving a release" do
    {out, code} = run_engine(["--todo"], [])
    assert code == 64
    assert out =~ "--todo expects one or more numeric issue IDs"
  end

  test "todo rejects nonnumeric IDs" do
    {out, code} = run_engine(["--todo", "11", "nope"], [])
    assert code == 64
    assert out =~ "--todo expects one or more numeric issue IDs"
  end

  test "only without todo exits 64" do
    {out, code} = run_engine(["--only"], [])
    assert code == 64
    assert out =~ "--only is valid only with --todo"
  end

  # Lifecycle commands generate + validate a cookie, whose owner must equal
  # $USER, so these run as the real user (only the state dir is redirected).
  defp run_engine_real(args, env) do
    System.cmd(@engine, args, env: env, stderr_to_stdout: true)
  end

  defp tmp_state, do: Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

  defp realpath(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp spawn_sleeper(cwd) do
    port = Port.open({:spawn_executable, "/bin/sh"}, [:binary, args: ["-c", "exec sleep 300"], cd: cwd])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  defp os_pid_alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))

  defp wait_dead(pid, attempts \\ 50)
  defp wait_dead(pid, 0), do: not os_pid_alive?(pid)

  defp wait_dead(pid, attempts) do
    if os_pid_alive?(pid) do
      Process.sleep(50)
      wait_dead(pid, attempts - 1)
    else
      true
    end
  end

  defp kill_pid(pid), do: System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)

  defp run_sourced_engine(script, env) do
    # The engine's launch/stop paths reap any BEAM holding their node name
    # (`kill_beams_matching "-name $AIUR_RELEASE_NODE"`). Sourced from `mix test`
    # on a host running a live aiur, an un-isolated run resolves the SAME node
    # name and reaps the operator's BEAM. Pin a unique, non-existent node unless
    # the caller set one, so these reaps can never match a real process.
    env =
      if List.keymember?(env, "AIUR_RELEASE_NODE", 0) do
        env
      else
        [{"AIUR_RELEASE_NODE", "aiur-enginetest-#{System.unique_integer([:positive])}@127.0.0.1"} | env]
      end

    System.cmd("bash", ["-c", "set -euo pipefail\nsource \"$AIUR_ENGINE\"\n#{script}"],
      env: [{"AIUR_ENGINE", @engine} | env],
      stderr_to_stdout: true
    )
  end

  defp fake_tmux_script(body) do
    dir = Path.join(System.tmp_dir!(), "aiur-fake-tmux-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "tmux")
    File.write!(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(dir) end)
    path
  end

  # Bare `pause`/`resume` used to be a usage error. It is now the global switch,
  # so only *malformed* targets still earn exit 64.
  test "pause with malformed targets exits 64 with guidance" do
    {out, code} = run_engine_real(["pause", "not-an-id"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "expects issue IDs or --all"
    assert out =~ "bare aiur pause for the global switch"
  end

  test "bare pause/resume RPC the global switch into the node" do
    rel = fake_release()
    state = tmp_state()

    {paused, _} = run_engine_real(["pause"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert paused =~ "Aiur.AgentControlCLI.pause_global()"

    {resumed, _} = run_engine_real(["resume"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert resumed =~ "Aiur.AgentControlCLI.resume_global()"
  end

  test "pause/resume RPC the AgentControlCLI expression into the node" do
    rel = fake_release()
    state = tmp_state()

    {paused, _} = run_engine_real(["pause", "44,45"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert paused =~ ~s|Aiur.AgentControlCLI.pause(["44", "45"])|

    {resumed, _} = run_engine_real(["resume", "--all"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])
    assert resumed =~ "Aiur.AgentControlCLI.resume(:all)"
  end

  test "usage RPCs the usage expression" do
    rel = fake_release()
    {out, _} = run_engine_real(["usage"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AgentControlCLI.usage()"
  end

  test "usage rejects arguments" do
    {out, code} = run_engine_real(["usage", "codex"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code != 0
    assert out =~ "usage does not accept arguments"
  end

  test "status RPCs the status expression" do
    rel = fake_release()
    {out, _} = run_engine_real(["status"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert out =~ "Aiur.AgentControlCLI.status()"
  end

  test "writes an instance record with launch identity metadata" do
    state = tmp_state()
    launch_root = Path.join(System.tmp_dir!(), "aiur-record-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(launch_root)

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(launch_root)
    end)

    script = """
    cd "$LAUNCH_ROOT"
    AIUR_BG_STATE_DIR="$STATE"
    AIUR_INSTANCE_KEY=abc123
    AIUR_RELEASE_NODE=aiur-tester-abc123@127.0.0.1
    AIUR_REPO_ROOT=
    aiur_resolve_identity
    write_aiur_instance_record aiur-tester-abc123-default aiur-tester-abc123
    cat "$(aiur_instance_record_path)"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"STATE", state},
        {"LAUNCH_ROOT", launch_root},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    launch_root_real = realpath(launch_root)

    assert out =~ "AIUR_RECORD_NODE=aiur-tester-abc123@127.0.0.1"
    assert out =~ "AIUR_RECORD_INSTANCE_KEY=abc123"
    assert out =~ "AIUR_RECORD_SESSION=aiur-tester-abc123-default"
    assert out =~ "AIUR_RECORD_SOCKET=aiur-tester-abc123"
    assert out =~ "AIUR_RECORD_PROJECT_ROOT=#{launch_root_real}"
    assert out =~ "AIUR_RECORD_PROJECT_ROOT_SOURCE=cwd"
  end

  test "global-config control RPC adopts the live launch record from a subdirectory" do
    rel = fake_release()

    File.write!(Path.join([rel, "bin", "aiur"]), """
    #!/usr/bin/env bash
    echo "NODE:$RELEASE_NODE"
    echo "__AIUR_CONTROL_EXIT__:0"
    """)

    state = tmp_state()
    base = Path.join(System.tmp_dir!(), "aiur-control-record-#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    launch_root = Path.join(base, "project")
    subdir = Path.join([launch_root, "nested", "dir"])
    File.mkdir_p!(home)
    File.mkdir_p!(subdir)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(base)
    end)

    live_node = "aiur-tester-live123@127.0.0.1"

    script = """
    AIUR_BG_STATE_DIR="$STATE"
    AIUR_RELEASE_NODE="$LIVE_NODE"
    AIUR_INSTANCE_KEY=live123
    AIUR_PROJECT_ROOT="$LAUNCH_ROOT"
    AIUR_PROJECT_ROOT_SOURCE=cwd
    write_aiur_instance_record aiur-tester-live123-default aiur-tester-live123

    cd "$SUBDIR"
    unset AIUR_RELEASE_NODE AIUR_INSTANCE_KEY AIUR_PROJECT_ROOT AIUR_PROJECT_ROOT_SOURCE
    AIUR_REPO_ROOT=
    probe_node_liveness() {
      case "$RELEASE_NODE" in
        "$LIVE_NODE") printf up ;;
        *) printf down ;;
      esac
    }
    run_control_rpc "Aiur.AgentControlCLI.status()"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"STATE", state},
        {"HOME", home},
        {"LAUNCH_ROOT", launch_root},
        {"SUBDIR", subdir},
        {"LIVE_NODE", live_node},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out =~ "NODE:#{live_node}"
    refute out =~ "no running aiur node"
  end

  test "down global-config control RPC prints the stopped-daemon error" do
    state = tmp_state()
    caller = Path.join(System.tmp_dir!(), "aiur-control-miss-#{System.unique_integer([:positive])}")
    File.mkdir_p!(caller)

    rpc = Path.join(System.tmp_dir!(), "aiur-rpc-down-#{System.unique_integer([:positive])}")
    File.write!(rpc, "#!/usr/bin/env bash\necho transport failed >&2\nexit 42\n")
    File.chmod!(rpc, 0o755)

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(caller)
      File.rm(rpc)
    end)

    script = """
    cd "$CALLER"
    resolve_release() { release_bin="$RPC"; release_dir=/tmp/nonexistent-aiur-release; }
    prepare_distribution() { aiur_resolve_identity; RELEASE_NODE="$AIUR_RELEASE_NODE"; }
    probe_node_liveness() { printf down; }
    run_control_rpc "Aiur.AgentControlCLI.status()"
    """

    {out, 1} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"CALLER", caller},
        {"RPC", rpc},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out ==
             "error: aiur is not running. Start it with `aiurdev run` (or `aiurdev --bg`), then retry.\n"
  end

  test "down control RPC with crash marker reports orphaned-agent guidance" do
    state = tmp_state()
    rpc = Path.join(System.tmp_dir!(), "aiur-rpc-fail-#{System.unique_integer([:positive])}")

    File.write!(rpc, "#!/usr/bin/env bash\necho transport failed >&2\nexit 42\n")
    File.chmod!(rpc, 0o755)

    on_exit(fn ->
      File.rm(rpc)
      File.rm_rf(state)
    end)

    script = """
    resolve_release() { :; }
    prepare_distribution() { :; }
    probe_node_liveness() { printf down; }
    release_bin="$RPC"
    mkdir -p "$AIUR_BG_STATE_DIR"
    echo "crash details" >"$(aiur_crash_marker_path)"
    if run_control_rpc "Aiur.AgentControlCLI.status()"; then
      code=0
    else
      code=$?
    fi
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"RELEASE_NODE", "aiur-crashed@127.0.0.1"},
        {"RPC", rpc}
      ])

    assert out =~ "background daemon at aiur-crashed@127.0.0.1 is DOWN after an unexpected exit"
    assert out =~ "crash details"
    assert out =~ "run 'aiur stop' to reap any orphaned agents"
    assert out =~ "CODE=1"
    refute out =~ "start aiur and try again"
  end

  test "background startup waits until the control plane is ready" do
    tmux = fake_tmux_script("exit 0")
    capture = Path.join(System.tmp_dir!(), "aiur-startup-#{System.unique_integer([:positive])}")
    counter = Path.join(System.tmp_dir!(), "aiur-control-probes-#{System.unique_integer([:positive])}")
    File.write!(capture, "")
    File.write!(counter, "0")

    on_exit(fn ->
      File.rm(capture)
      File.rm(counter)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() {
      calls="$(cat "$COUNTER")"
      calls=$((calls + 1))
      printf '%s' "$calls" > "$COUNTER"
      if [ "$calls" -lt 3 ]; then printf down; else printf up; fi
    }
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    echo "CALLS=$(cat "$COUNTER")"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"COUNTER", counter},
        {"AIUR_NODE_GRACE_TICKS", "5"}
      ])

    assert out =~ "CALLS=3"
  end

  test "background startup fails when the node never registers" do
    tmux = fake_tmux_script("exit 0")
    capture = Path.join(System.tmp_dir!(), "aiur-startup-#{System.unique_integer([:positive])}")
    File.write!(capture, "node boot log\n")
    on_exit(fn -> File.rm(capture) end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf down; }
    set +e
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    code=$?
    set -e
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"RELEASE_NODE", "aiur-test@127.0.0.1"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "aiur control plane did not become ready at aiur-test@127.0.0.1 during startup"
    assert out =~ "node boot log"
  end

  test "startup wait reports tmux exits with captured output" do
    tmux = fake_tmux_script(~s|case " $* " in *" has-session "*) exit 1 ;; *) exit 0 ;; esac|)
    capture = Path.join(System.tmp_dir!(), "aiur-startup-#{System.unique_integer([:positive])}")
    File.write!(capture, "boot failed\n")
    on_exit(fn -> File.rm(capture) end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    set +e
    wait_for_session_startup "$FAKE_TMUX" sock conf session "$CAPTURE" 1
    code=$?
    set -e
    echo "CODE=$code"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"FAKE_TMUX", tmux},
        {"CAPTURE", capture},
        {"AIUR_NODE_GRACE_TICKS", "2"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "aiur exited during startup"
    assert out =~ "boot failed"
  end

  test "background startup failure cleans generated tempfiles and reaps session" do
    rel = fake_release()
    state = tmp_state()
    tmp = Path.join(System.tmp_dir!(), "aiur-bg-fail-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    tmux_state = Path.join(tmp, "tmux-session")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
      File.rm(events)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    export XDG_RUNTIME_DIR="$TMP_ROOT"
    mktemp() {
      case "$1" in
        */aiur-argv.*) path="$TMP_ROOT/argv" ;;
        */aiur-startup.*) path="$TMP_ROOT/startup" ;;
        */aiur-pane.*) path="$TMP_ROOT/launcher" ;;
        *) command mktemp "$@" ;;
      esac
      : > "$path"
      printf '%s\\n' "$path"
    }
    sleep() { :; }
    probe_control_liveness() { printf down; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    expected_session="$TMP_ROOT/aiur-$$-sessions"
    expected_agents="$TMP_ROOT/aiur-$$-agents"
    expected_workspace_root="$TMP_ROOT/aiur-$$-workspace-root"
    set +e
    ( run_session background )
    code=$?
    set -e
    echo "CODE=$code"
    for path in "$TMP_ROOT/argv" "$TMP_ROOT/startup" "$TMP_ROOT/launcher" "$expected_session" "$expected_agents" "$expected_workspace_root"; do
      if [ -e "$path" ]; then echo "LEFT:${path##*/}"; else echo "REMOVED:${path##*/}"; fi
    done
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path},
        {"TMP_ROOT", tmp}
      ])

    assert out =~ "CODE=1"
    assert out =~ "KILL_SESSION:"
    assert out =~ "REAP:aiur-"
    assert out =~ "KILL_BEAM:-name aiur-"
    assert out =~ "REMOVED:argv"
    assert out =~ "REMOVED:startup"
    assert out =~ "REMOVED:launcher"
    assert out =~ "REMOVED:aiur-"
    refute out =~ "LEFT:"
  end

  test "foreground startup failure before control readiness exits nonzero and preserves output" do
    rel = fake_release()
    state = tmp_state()
    tmp = Path.join(System.tmp_dir!(), "aiur-fg-fail-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    tmux_state = Path.join(tmp, "tmux-session")
    File.mkdir_p!(tmp)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          touch "#{tmux_state}"
          echo "Failed to start Aiur with workflow test-config" >> "#{Path.join(tmp, "startup")}"
          exit 0
          ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" attach "*) echo "ATTACH:$*" >> "#{events}"; exit 0 ;;
        *" kill-session "*) echo "KILL_SESSION:$*" >> "#{events}"; rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(tmp)
      File.rm(events)
    end)

    script = """
    export TMPDIR="$TMP_ROOT"
    export XDG_RUNTIME_DIR="$TMP_ROOT"
    mktemp() {
      case "$1" in
        */aiur-argv.*) path="$TMP_ROOT/argv" ;;
        */aiur-startup.*) path="$TMP_ROOT/startup" ;;
        */aiur-pane.*) path="$TMP_ROOT/launcher" ;;
        */aiur-attach.*) path="$TMP_ROOT/attach" ;;
        *) command mktemp "$@"; return ;;
      esac
      : > "$path"
      printf '%s\\n' "$path"
    }
    sleep() { :; }
    probe_control_liveness() { printf down; }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    set +e
    ( run_session foreground )
    code=$?
    set -e
    echo "CODE=$code"
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path},
        {"TMP_ROOT", tmp}
      ])

    assert out =~ "CODE=1"
    assert out =~ ~r/aiur control plane did not become ready at aiur-enginetest-\d+@127\.0\.0\.1 during startup/
    assert out =~ "Failed to start Aiur with workflow test-config"
    assert out =~ "KILL_SESSION:"
    assert out =~ "REAP:aiur-"
    assert out =~ "KILL_BEAM:-name aiur-"
    refute out =~ "ATTACH:"
  end

  test "seeded BEAM watchdog reaps immediately when the node disappears" do
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    File.write!(events, "")
    on_exit(fn -> File.rm(events) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    pattern="aiur-watchdog-${$}-absent"
    first_pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1)"
    for _ in $(seq 1 20); do
      [ -s "$EVENTS" ] && break
      sleep 0.05
    done
    kill "$first_pid" 2>/dev/null || true
    echo "SEEDED=$(cat "$EVENTS")"

    : > "$EVENTS"
    second_pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 0)"
    sleep 0.15
    if [ -s "$EVENTS" ]; then echo "DEFAULT_REAPED"; else echo "DEFAULT_WAITED"; fi
    kill "$second_pid" 2>/dev/null || true
    """

    {out, 0} = run_sourced_engine(script, [{"EVENTS", events}])

    assert out =~ "SEEDED=REAP:sock pidfile"
    assert out =~ "DEFAULT_WAITED"
    refute out =~ "DEFAULT_REAPED"
  end

  test "background run arms the detached BEAM watchdog before success" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
      File.rm(events)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() {
      echo PROBE >> "$EVENTS"
      printf up
    }
    probe_dashboard_url() { printf 'http://127.0.0.1:4567'; }
    start_beam_death_watchdog() {
      echo "WATCHDOG:$*" >> "$EVENTS"
      printf '424242\\n'
    }
    disown() { echo "DISOWN:$*" >> "$EVENTS"; }
    aiur_engine_main run --bg
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "aiur started in the background"
    assert out =~ "Dashboard: http://127.0.0.1:4567"
    events_log = File.read!(events)
    assert events_log =~ "PROBE\nWATCHDOG:-name aiur-"
    assert events_log =~ ~r/ 1 1 aiur-\S+ \S+ \S+\.stopping \S+\.last-crash \S+-workspace-root\n/
    assert events_log =~ "DISOWN:424242"
  end

  test "background launch with --no-dashboard in either-order form reports explicit suppression" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    probe_dashboard_url() { :; }
    start_beam_death_watchdog() { printf '424242\n'; }
    disown() { :; }
    aiur_engine_main --no-dashboard --bg
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"PATH", path}
      ])

    assert out =~ "Dashboard disabled by --no-dashboard."
    assert out =~ "aiur started in the background"
    refute out =~ "dashboard listener unavailable"
  end

  test "foreground attach filters tmux server-exited noise without process substitution" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*) touch "#{tmux_state}"; exit 0 ;;
        *" has-session "*) [ -f "#{tmux_state}" ]; exit $? ;;
        *" attach "*) echo "[server exited]" >&2; echo "real attach error" >&2; exit 7 ;;
        *" kill-session "*) rm -f "#{tmux_state}"; exit 0 ;;
        *) exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(tmux_state)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() { printf '424242\\n'; }
    set +e
    ( run_session foreground --no-dashboard )
    code=$?
    set -e
    echo "CODE=$code"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"PATH", path}
      ])

    assert out =~ "CODE=7"
    assert out =~ "real attach error"
    refute out =~ "[server exited]"
  end

  test "stop does not terminate sibling instances from the same release dir" do
    rel = fake_release()
    File.mkdir_p!(Path.join([rel, "erts-16.4", "bin"]))

    state = tmp_state()
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")

    sibling_marker =
      "#{Path.join([rel, "erts-16.4", "bin", "beam.smp"])} -name aiur-sibling-#{System.unique_integer([:positive])}@127.0.0.1"

    File.write!(events, "")
    tmux = fake_tmux_script("exit 0")

    on_exit(fn ->
      System.cmd("pkill", ["-f", sibling_marker], stderr_to_stdout: true)
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm(events)
    end)

    script = """
    bash -c 'exec -a "$SIBLING_MARKER" sleep 20' >/dev/null 2>&1 &
    sibling_pid=$!
    for _ in $(seq 1 20); do
      pgrep -f -- "$SIBLING_MARKER" >/dev/null && break
      sleep 0.05
    done
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    cmd_stop
    if kill -0 "$sibling_pid" 2>/dev/null; then echo "SIBLING_ALIVE"; else echo "SIBLING_DEAD"; fi
    kill "$sibling_pid" 2>/dev/null || true
    cat "$EVENTS"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", path},
        {"SIBLING_MARKER", sibling_marker},
        {"USER", "tester"}
      ])

    assert out =~ "SIBLING_ALIVE"
    refute out =~ "SIBLING_DEAD"
    assert out =~ "KILL_BEAM:-name aiur-"
  end

  test "cmd_stop marks a clean stop before killing the BEAM and cwd sweep" do
    state = tmp_state()
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(System.tmp_dir!(), "aiur-workspaces-#{System.unique_integer([:positive])}")
    workspace_root_file = Path.join(System.tmp_dir!(), "aiur-workspace-root-#{System.unique_integer([:positive])}")
    record = Path.join(System.tmp_dir!(), "aiur-stop-record-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace_root)
    File.write!(workspace_root_file, workspace_root <> "\n")

    File.write!(
      record,
      """
      AIUR_RECORD_NODE=aiur-enginetest@127.0.0.1
      AIUR_RECORD_SESSION=aiur-tester-default
      AIUR_RECORD_SOCKET=aiur-tester
      AIUR_RECORD_PROJECT_ROOT=/tmp/aiur-project
      AIUR_RECORD_WORKSPACE_ROOT_FILE=#{inspect(workspace_root_file)}
      """
    )

    tmux = fake_tmux_script("exit 0")

    on_exit(fn ->
      File.rm_rf(state)
      File.rm_rf(workspace_root)
      File.rm(workspace_root_file)
      File.rm(record)
      File.rm(events)
    end)

    script = """
    resolve_release() { :; }
    aiur_resolve_identity() {
      : "${AIUR_SESSION_PREFIX:=aiur}"
      : "${AIUR_RELEASE_NODE:=aiur-enginetest@127.0.0.1}"
    }
    aiur_instance_record_path() { printf '%s' "$RECORD"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    kill_beams_matching() {
      echo "KILL_BEAM:$*" >> "$EVENTS"
      [ -f "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_PRESENT_BEFORE_KILL" >> "$EVENTS"
      [ ! -f "$(aiur_crash_marker_path)" ] && echo "CRASH_MARKER_CLEARED_BEFORE_KILL" >> "$EVENTS"
    }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    mkdir -p "$AIUR_BG_STATE_DIR"
    echo stale >"$(aiur_crash_marker_path)"
    cmd_stop
    cat "$EVENTS"
    [ -f "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_LEFT_FOR_WATCHDOG"
    [ -e "$(aiur_crash_marker_path)" ] && echo "CRASH_MARKER_STILL_PRESENT" || echo "CRASH_MARKER_REMOVED"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_BG_STATE_DIR", state},
        {"EVENTS", events},
        {"PATH", path},
        {"RECORD", record},
        {"USER", "tester"}
      ])

    assert out =~ "SENTINEL_PRESENT_BEFORE_KILL"
    assert out =~ "CRASH_MARKER_CLEARED_BEFORE_KILL"
    assert out =~ "CWD_REAP:#{workspace_root}"
    assert out =~ "SENTINEL_LEFT_FOR_WATCHDOG"
    assert out =~ "CRASH_MARKER_REMOVED"
    refute out =~ "CRASH_MARKER_STILL_PRESENT"
  end

  test "cmd_stop still tears down the session without a workspace root handoff" do
    state = tmp_state()
    events = Path.join(System.tmp_dir!(), "aiur-stop-timeout-#{System.unique_integer([:positive])}")
    File.write!(events, "")

    on_exit(fn ->
      File.rm_rf(state)
      File.rm(events)
    end)

    script = """
    resolve_release() { :; }
    aiur_resolve_identity() {
      : "${AIUR_SESSION_PREFIX:=aiur}"
      : "${AIUR_RELEASE_NODE:=aiur-enginetest@127.0.0.1}"
    }
    resolve_control_identity_from_records() { AIUR_CONTROL_ADOPTED_RECORD=0; AIUR_CONTROL_CURRENT_NODE_STATE=up; }
    workspace_root_file_from_instance_record() { return 1; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    sweep_dead_tmux_sockets() { :; }
    sweep_stale_tmp_artifacts() { :; }
    reap_aiur_agents() { :; }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    cmd_stop
    cat "$EVENTS"
    """

    {out, 0} = run_sourced_engine(script, [{"AIUR_BG_STATE_DIR", state}, {"EVENTS", events}])

    assert out =~ "KILL_BEAM:-name aiur-enginetest-"
  end

  test "cmd_stop fails loud instead of no-oping for an unmatched global-config cwd" do
    rel = fake_release()
    state = tmp_state()
    events = Path.join(System.tmp_dir!(), "aiur-stop-miss-events-#{System.unique_integer([:positive])}")
    caller = Path.join(System.tmp_dir!(), "aiur-stop-miss-#{System.unique_integer([:positive])}")
    File.mkdir_p!(caller)
    File.write!(events, "")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" has-session "*) exit 1 ;;
        *) echo "TMUX:$*" >> "$EVENTS"; exit 0 ;;
      esac
      """)

    on_exit(fn ->
      File.rm_rf(rel)
      File.rm_rf(state)
      File.rm_rf(caller)
      File.rm(events)
    end)

    script = """
    cd "$CALLER"
    current_workspace_root() { return 1; }
    probe_node_liveness() { printf down; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    reap_workspace_cwd_agents() { echo "CWD_REAP:$1" >> "$EVENTS"; }
    set +e
    cmd_stop
    code=$?
    set -e
    echo "CODE=$code"
    cat "$EVENTS"
    [ -e "$(aiur_stop_sentinel_path)" ] && echo "SENTINEL_WRITTEN" || echo "NO_SENTINEL"
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"CALLER", caller},
        {"EVENTS", events},
        {"PATH", path},
        {"AIUR_RELEASE_NODE", nil},
        {"AIUR_INSTANCE_KEY", nil},
        {"AIUR_REPO_ROOT", nil}
      ])

    assert out =~ "CODE=1"
    assert out =~ "nothing stopped"
    refute out =~ "global-config control identity is keyed by cwd"
    assert out =~ "NO_SENTINEL"
    refute out =~ "KILL_BEAM:"
    refute out =~ "CWD_REAP:"
  end

  test "message RPCs the message expression with base64-encoded text" do
    rel = fake_release()

    {out, _} =
      run_engine_real(
        ["message", "44", "ship it"],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    encoded = Base.encode64("ship it")
    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{encoded}"))|
  end

  test "message base64-transports hostile text so it cannot break the RPC expression" do
    rel = fake_release()
    # Quotes, backslash, Elixir interpolation, and a newline — the exact characters
    # the base64 hop exists to neutralize.
    hostile = ~s|say "hi" #{"\#{System.halt}"} \\o/| <> "\nline2"

    {out, _} =
      run_engine_real(
        ["message", "44", hostile],
        [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]
      )

    assert out =~ ~s|Aiur.AgentControlCLI.message("44", Base.decode64!("#{Base.encode64(hostile)}"))|
    # The raw text never reaches the expression un-encoded.
    refute out =~ ~s|say "hi"|
    refute out =~ "System.halt"
  end

  test "message without text exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "44"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message with a non-numeric issue id exits 64 with guidance" do
    {out, code} = run_engine_real(["message", "abc", "hi"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  test "message without an issue exits 64 with guidance" do
    {out, code} = run_engine_real(["message"], [{"AIUR_RELEASE_DIR", fake_release()}])
    assert code == 64
    assert out =~ "message expects an issue ID and text"
  end

  # --- stale /tmp artifact reaping (#334) -------------------------------------
  #
  # The reaper only ever scans the temp roots TMPDIR / XDG_RUNTIME_DIR point at,
  # so each test redirects both at a throwaway mktemp dir — the real /tmp is never
  # touched. Old mtimes use `touch -t CCYYMMDDhhmm`, which both GNU and BSD touch
  # accept, so these run identically on Linux CI and macOS dev.

  test "sweep_stale_tmp_artifacts reaps stale known debris and spares live/fresh/non-matching" do
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-test.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"

    touch -t "$OLD" "$T/aiur-argv.STALE"
    touch "$T/aiur-argv.FRESH"
    mkdir -p "$T/aiur-rc"; touch "$T/aiur-rc/live.log"; touch -t "$OLD" "$T/aiur-rc"
    mkdir -p "$T/aiur-debug"; touch -t "$OLD" "$T/aiur-debug/old.log"; touch -t "$OLD" "$T/aiur-debug"
    mkdir -p "$T/aiur-pr123"; touch -t "$OLD" "$T/aiur-pr123/checkout"; touch -t "$OLD" "$T/aiur-pr123"
    mkdir -p "$T/aiur_workspaces/w"; touch -t "$OLD" "$T/aiur_workspaces/w/f"; touch -t "$OLD" "$T/aiur_workspaces"
    mkdir -p "$T/aiur100-hex"; touch -t "$OLD" "$T/aiur100-hex/c"; touch -t "$OLD" "$T/aiur100-hex"
    touch -t "$OLD" "$T/aiur-user-note.txt"
    touch -t "$OLD" "$T/aiur-4000000000-agents"
    sleep 30 & LIVE=$!
    touch -t "$OLD" "$T/aiur-$LIVE-agents"
    touch -t "$OLD" "$T/unrelated.txt"

    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=60 sweep_stale_tmp_artifacts

    chk(){ if [ "$2" = present ]; then [ -e "$T/$1" ] && echo "PASS $1" || echo "FAIL $1 expected-present"; else [ -e "$T/$1" ] && echo "FAIL $1 expected-gone" || echo "PASS $1"; fi; }
    chk aiur-argv.STALE gone
    chk aiur-argv.FRESH present
    chk aiur-rc present
    chk aiur-debug gone
    chk aiur-pr123 present
    chk aiur_workspaces present
    chk aiur100-hex present
    chk aiur-user-note.txt present
    chk aiur-4000000000-agents gone
    chk "aiur-$LIVE-agents" present
    chk unrelated.txt present
    kill "$LIVE" 2>/dev/null || true
    rm -rf "$T"
    """

    {out, code} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert code == 0, "fixture script aborted:\n#{out}"
    refute out =~ "FAIL", "unexpected reaper outcome:\n#{out}"

    # Each outcome asserted by name so a regression names exactly what drifted.
    for name <- ~w(aiur-argv.STALE aiur-argv.FRESH aiur-rc aiur-debug aiur_workspaces
                   aiur-pr123 aiur100-hex aiur-user-note.txt aiur-4000000000-agents
                   unrelated.txt) do
      assert out =~ "PASS #{name}", "missing PASS #{name} in:\n#{out}"
    end

    # The live-pid pidfile (name carries a runtime pid) was spared.
    assert out =~ ~r/PASS aiur-\d+-agents/
  end

  test "sweep_stale_tmp_artifacts default window spares artifacts younger than 24h" do
    # A 3-hour-old artifact must survive the conservative 1440-minute default —
    # this is the guard that a same-day dev/test run is never reaped out from under.
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-default.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.RECENT"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.RECENT" ] && echo "KEPT" || echo "GONE"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT"
    refute out =~ "GONE"
  end

  test "sweep_stale_tmp_artifacts is disabled by a 0 or non-numeric AIUR_TMP_REAP_MINUTES" do
    script = """
    source #{@engine}
    T="$(mktemp -d "${TMPDIR:-/tmp}/aiur-reap-off.XXXXXX")"
    OLD="$(date -d '3 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-3H +%Y%m%d%H%M)"
    touch -t "$OLD" "$T/aiur-argv.STALE"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=0 sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-ZERO" || echo "GONE-ZERO"
    TMPDIR="$T" XDG_RUNTIME_DIR="$T" AIUR_TMP_REAP_MINUTES=abc sweep_stale_tmp_artifacts
    [ -e "$T/aiur-argv.STALE" ] && echo "KEPT-NAN" || echo "GONE-NAN"
    rm -rf "$T"
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    assert out =~ "KEPT-ZERO"
    assert out =~ "KEPT-NAN"
    refute out =~ "GONE"
  end
end
