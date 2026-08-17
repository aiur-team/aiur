defmodule AiurEngineTest do
  use ExUnit.Case, async: true

  @engine Path.expand("../../packaging/npm/aiur-cli/libexec/aiur-engine.sh", __DIR__)
  @cli_package Path.expand("../../packaging/npm/aiur-cli/package.json", __DIR__)
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

  test "run refuses a legacy config before release startup" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-legacy-config-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(@engine, [],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ ".aiurconfig is no longer supported"
    assert out =~ ".aiur/config"
    assert out =~ "relative prompt_file and hooks_file paths"
    refute out =~ "release not found"
  end

  test "legacy preflight checks the global fallback but canonical config wins" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-global-legacy-config-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(home, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(home, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"HOME", home},
      {"AIUR_REPO_ROOT", nil},
      {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
      {"USER", "tester"}
    ]

    {legacy_out, 1} = System.cmd(@engine, [], cd: repo, env: env, stderr_to_stdout: true)
    assert legacy_out =~ ".aiurconfig is no longer supported"

    File.mkdir_p!(Path.join(home, ".aiur"))
    File.write!(Path.join([home, ".aiur", "config"]), "tracker:\n  kind: memory\n")

    {canonical_out, 1} = System.cmd(@engine, [], cd: repo, env: env, stderr_to_stdout: true)
    refute canonical_out =~ ".aiurconfig is no longer supported"
    assert canonical_out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "run refuses an explicit named legacy config before release startup" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-explicit-legacy-config-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    legacy = Path.join(repo, "portable.aiurconfig")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(legacy, "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(@engine, [legacy],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ "portable.aiurconfig is no longer supported"
    assert out =~ "portable.yaml"
    refute out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "legacy preflight does not mistake option values for config paths" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-legacy-option-value-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(repo, ".aiur"))
    File.write!(Path.join([repo, ".aiur", "config"]), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(@engine, ["--bg", "--logs-root", Path.join(root, "archive.aiurconfig")],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", nil},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    refute out =~ "aiurconfig is no longer supported"
    refute out =~ "basename:"
    assert out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "explicit repo root still checks the global legacy fallback" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-explicit-root-global-legacy-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(home, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(@engine, [],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", repo},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    assert out =~ Path.join(home, ".aiurconfig")
    assert out =~ "is no longer supported"
    refute out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "an explicit canonical config wins over an ambient legacy file" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-explicit-canonical-config-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    canonical = Path.join(root, "portable.yaml")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    File.write!(canonical, "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      System.cmd(@engine, [canonical],
        cd: repo,
        env: [
          {"HOME", home},
          {"AIUR_REPO_ROOT", repo},
          {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
          {"USER", "tester"}
        ],
        stderr_to_stdout: true
      )

    assert code == 1
    refute out =~ "aiurconfig is no longer supported"
    assert out =~ "AIUR_RELEASE_DIR does not exist"
  end

  test "argument terminator preserves dashed explicit config precedence" do
    root = Path.join(System.tmp_dir!(), "aiur-engine-dashed-explicit-config-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    repo = Path.join(root, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, ".aiurconfig"), "tracker:\n  kind: memory\n")
    File.write!(Path.join(repo, "--portable.yaml"), "tracker:\n  kind: memory\n")
    File.write!(Path.join(repo, "--portable.aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    env = [
      {"HOME", home},
      {"AIUR_REPO_ROOT", repo},
      {"AIUR_RELEASE_DIR", Path.join(root, "missing-release")},
      {"USER", "tester"}
    ]

    {canonical_out, 1} = System.cmd(@engine, ["--", "--portable.yaml"], cd: repo, env: env, stderr_to_stdout: true)
    refute canonical_out =~ "aiurconfig is no longer supported"
    assert canonical_out =~ "AIUR_RELEASE_DIR does not exist"

    {legacy_out, 1} = System.cmd(@engine, ["--", "--portable.aiurconfig"], cd: repo, env: env, stderr_to_stdout: true)
    assert legacy_out =~ "--portable.aiurconfig is no longer supported"
    assert legacy_out =~ "--portable.yaml"
    refute legacy_out =~ "basename:"
  end

  test "usage describes init and no longer lists sweep" do
    {out, 0} = run_engine(["--help"], [])
    assert out =~ ~r/aiur init \[--force\]\s+scaffold/
    assert out =~ "aiur --todo <ids...> [--only]"
    assert out =~ "aiur findings [--unfiled] [--slugs] [--scope aiur|repo]"
    assert out =~ "aiur findings --record <json> --repo <owner/repo>"
    assert out =~ "aiur findings --digest [--scope aiur|repo]"
    assert out =~ "aiur ask <title> [--body <text>|--body-file <path>] [--urgency low|normal|high] [--blocking]"
    assert out =~ "aiur asks [--open|--all] [--json]"
    assert out =~ "aiur run [--bg] [--no-dashboard] [--executor] [--debug]"
    assert out =~ "aiur --bg [--no-dashboard] [--executor] [--debug]"
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

  test "run argv leaves dashboard host resolution to config unless explicitly overridden" do
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
    assert background =~ "--host|127.0.0.1|"
    refute background =~ "--no-dashboard|"
    assert lean_background =~ "--headless|"
    assert lean_background =~ "--no-dashboard|"
    refute lean_background =~ "--host|"
    assert foreground =~ "--interactive|"
    assert foreground =~ "--no-dashboard|"
    refute foreground =~ "--headless|"
    refute foreground =~ "--host|"
  end

  test "dashboard startup status reports a bound URL, explicit suppression, or listener refusal" do
    script = """
    probe_dashboard_status() { printf '%s' "$PROBE_STATUS"; }
    print_dashboard_status 0 /tmp/boot.log
    PROBE_STATUS=""
    print_dashboard_status 1 /tmp/boot.log
    print_dashboard_status 0 /tmp/boot.log
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"PROBE_STATUS", "Dashboard: http://127.0.0.1:4567 (bind host=0.0.0.0, port=4567)"}
      ])

    assert out =~ "Dashboard: http://127.0.0.1:4567"
    assert out =~ "bind host=0.0.0.0, port=4567"
    assert out =~ "Dashboard disabled by --no-dashboard."
    assert out =~ "dashboard listener unavailable; inspect /tmp/boot.log"
  end

  test "dashboard status probe is bounded by the control RPC timeout" do
    script = """
    run_release_rpc_with_timeout() {
      AIUR_CONTROL_RPC_OUTPUT=""
      AIUR_CONTROL_RPC_TIMED_OUT=1
      return 124
    }
    test -z "$(probe_dashboard_status)" && echo BOUNDED
    """

    {out, 0} = run_sourced_engine(script, [])

    assert out =~ "BOUNDED"
  end

  test "config startup status replays the exact selected path from boot output" do
    capture = Path.join(System.tmp_dir!(), "aiur config capture #{System.unique_integer([:positive])}")
    config = "/tmp/operator config/.aiur/config"
    File.write!(capture, "booting\n__AIUR_CONFIG_PATH__:#{config}\nready\n")
    on_exit(fn -> File.rm(capture) end)

    {out, 0} = run_sourced_engine(~s(print_config_status "#{capture}"), [])

    assert out == "Config: #{config}\n"
  end

  test "config startup status makes a missing selection marker visible" do
    capture = Path.join(System.tmp_dir!(), "aiur-empty-capture-#{System.unique_integer([:positive])}")
    File.write!(capture, "booting\n")
    on_exit(fn -> File.rm(capture) end)

    {out, 0} = run_sourced_engine(~s(print_config_status "#{capture}"), [])

    assert out =~ "selected config path unavailable"
    assert out =~ "captured startup output"
    refute out =~ capture
  end

  test "control readiness waits for full application startup before dashboard reporting" do
    engine = File.read!(@engine)

    assert engine =~ "Application.started_applications()"
    assert engine =~ "app == :aiur"
    assert engine =~ ~r/write_aiur_instance_record.*print_config_status.*print_dashboard_status/s
    assert engine =~ ~r/if ! wait_for_session_startup.*then\n\s+print_config_status/s
  end

  test "--version is distribution-free so it never collides with a running node" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")
    elixir = Path.join([rel, "releases", "0.1.1", "elixir"])
    cli_version = @cli_package |> File.read!() |> Jason.decode!() |> Map.fetch!("version")

    File.write!(elixir, "#!/usr/bin/env bash\necho \"CLI_VERSION=$AIUR_CLI_VERSION\"\necho \"ELIXIR_ARGS: $*\"\n")

    {out, _} = run_engine(["--version"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

    # Runs through the start_clean `elixir --eval` path (like init), never the
    # distributed release start script — so it claims no node name.
    assert out =~ "ELIXIR_ARGS:"
    assert out =~ "--eval"
    assert out =~ "CLI_VERSION=#{cli_version}"
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
    refute out =~ "installed CLI"
  end

  test "an unknown command diagnoses a dispatcher older than its stamped checkout" do
    root = Path.join(System.tmp_dir!(), "aiur-stale-cli-#{System.unique_integer([:positive])}")
    installed_libexec = Path.join([root, "installed", "libexec"])
    checkout_package = Path.join([root, "checkout", "packaging", "npm", "aiur-cli"])
    release = Path.join(root, "release")

    File.mkdir_p!(installed_libexec)
    File.mkdir_p!(checkout_package)
    File.mkdir_p!(release)
    File.write!(Path.join(root, "installed/package.json"), "{\n  \"version\": \"1.2.3\"\n}\n")
    File.write!(Path.join(checkout_package, "package.json"), "{\n  \"version\": \"1.3.0\"\n}\n")
    File.write!(Path.join(release, "AIUR_BUILD_STAMP"), "repo_root=#{Path.join(root, "checkout")}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_sourced_engine(
        ~S|engine_dir="$INSTALLED_LIBEXEC"; aiur_engine_main bogus-not-a-path|,
        [{"INSTALLED_LIBEXEC", installed_libexec}, {"AIUR_RELEASE_DIR", release}]
      )

    assert code == 64
    assert out =~ "installed CLI 1.2.3 is older than checkout CLI 1.3.0"
    assert out =~ "update aiur-cli before retrying"
    assert out =~ "Usage: aiur"
  end

  test "stale dispatcher diagnosis supports prerelease versions" do
    root = Path.join(System.tmp_dir!(), "aiur-stale-prerelease-cli-#{System.unique_integer([:positive])}")
    installed_libexec = Path.join([root, "installed", "libexec"])
    checkout_package = Path.join([root, "checkout", "packaging", "npm", "aiur-cli"])
    release = Path.join(root, "release")

    File.mkdir_p!(installed_libexec)
    File.mkdir_p!(checkout_package)
    File.mkdir_p!(release)

    File.write!(
      Path.join(root, "installed/package.json"),
      "{\n  \"version\": \"1.2.3-nightly.abcdef0+local\"\n}\n"
    )

    File.write!(Path.join(checkout_package, "package.json"), "{\n  \"version\": \"1.2.3\"\n}\n")
    File.write!(Path.join(release, "AIUR_BUILD_STAMP"), "repo_root=#{Path.join(root, "checkout")}\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_sourced_engine(
        ~S|engine_dir="$INSTALLED_LIBEXEC"; aiur_engine_main bogus-not-a-path|,
        [{"INSTALLED_LIBEXEC", installed_libexec}, {"AIUR_RELEASE_DIR", release}]
      )

    assert code == 64
    assert out =~ "installed CLI 1.2.3-nightly.abcdef0+local is older than checkout CLI 1.2.3"
    assert out =~ "Usage: aiur"
  end

  test "version comparison warns only when the installed CLI is older" do
    {out, 0} =
      run_sourced_engine(
        """
        version_is_older 1.2.3 1.2.3 && echo equal-older || true
        version_is_older 1.2.4 1.2.3 && echo newer-older || true
        version_is_older 1.2.3 1.2.4 && echo patch-older
        version_is_older 1.2.3-nightly.aaaaaaa 1.2.3-nightly.bbbbbbb && echo prerelease-older
        version_is_older not-semver 1.2.3 && echo malformed-older || true
        """,
        []
      )

    assert out =~ "patch-older"
    assert out =~ "prerelease-older"
    refute out =~ "equal-older"
    refute out =~ "newer-older"
    refute out =~ "malformed-older"
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

  test "commands routes filters and encoded detail arguments through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_commands dec:42 --filter resolved --json --limit 10|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.commands([filter: :resolved, json: true, limit: 10, decision_id: Base.decode64!(\"ZGVjOjQy\")])"
  end

  test "units routes page-visible filters through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units --scope unfinished --condition queued,alert --json|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"dW5maW5pc2hlZA==\"), conditions: [Base.decode64!(\"cXVldWVk\"), Base.decode64!(\"YWxlcnQ=\")], json: true])"
  end

  test "units forwards the human layout format" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units --format records|,
        []
      )

    assert out =~
             "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"bGl2ZQ==\"), format: Base.decode64!(\"cmVjb3Jkcw==\")])"

    {err, 64} = run_sourced_engine(~s|cmd_units --format|, [])
    assert err =~ "units --format requires a value"
  end

  test "bare units invocation routes an empty condition list" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_units|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.units([scope: Base.decode64!(\"bGl2ZQ==\")])"
  end

  test "commands reports missing option values as usage errors" do
    {out, 64} = run_sourced_engine(~s|cmd_commands --filter|, [])
    assert out =~ "commands --filter requires a value"
  end

  test "executor-answer safely routes one option answer through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_answer 'decision:42' --expected-version 3 --option rebase --rationale 'Known stale branch' --idempotency-key 'exec:42:v3' --executor-id codex-executor|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.executor_answer(["
    assert out =~ "decision_id: Base.decode64!(\"ZGVjaXNpb246NDI=\")"
    assert out =~ "expected_version: 3"
    assert out =~ "option_id: Base.decode64!(\"cmViYXNl\")"
    assert out =~ "rationale: Base.decode64!(\"S25vd24gc3RhbGUgYnJhbmNo\")"
    assert out =~ "idempotency_key: Base.decode64!(\"ZXhlYzo0Mjp2Mw==\")"
    assert out =~ "executor_id: Base.decode64!(\"Y29kZXgtZXhlY3V0b3I=\")"
  end

  test "executor mutations describe their attempted decision and version to the wrapper" do
    for {function, args} <- [
          {"cmd_executor_answer", "'decision:42' --expected-version 3 --option yes --rationale why --idempotency-key key"},
          {"cmd_executor_escalate", "'decision:42' --expected-version 3 --reason why"}
        ] do
      {out, 0} =
        run_sourced_engine(
          ~s|run_control_rpc() { echo "CONTEXT:$AIUR_CONTROL_ATTEMPT_CONTEXT"; }\n#{function} #{args}|,
          []
        )

      assert out =~ "CONTEXT:decision ID decision:42 with expected version 3"
    end
  end

  test "executor-answer requires one choice and all concurrency/audit fields" do
    for {argv, message} <- [
          {~s|'decision:42' --expected-version 3 --rationale why --idempotency-key key|, "exactly one of --option or --custom-response"},
          {~s|'decision:42' --expected-version 3 --option yes --custom-response yes --rationale why --idempotency-key key|, "exactly one of --option or --custom-response"},
          {~s|'decision:42' --option yes --rationale why --idempotency-key key|, "--expected-version expects a positive integer"},
          {~s|'decision:42' --expected-version 3 --option yes --idempotency-key key|, "--rationale is required"},
          {~s|'decision:42' --expected-version 3 --option yes --rationale why|, "--idempotency-key is required"}
        ] do
      {out, 64} = run_sourced_engine("cmd_executor_answer #{argv}", [])
      assert out =~ message
    end
  end

  test "executor-escalate safely routes one explicit operator alert" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_escalate 'decision:42' --expected-version 3 --reason 'Irreversible scope change' --executor-id codex-executor|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.executor_escalate(["
    assert out =~ "decision_id: Base.decode64!(\"ZGVjaXNpb246NDI=\")"
    assert out =~ "expected_version: 3"
    assert out =~ "reason: Base.decode64!(\"SXJyZXZlcnNpYmxlIHNjb3BlIGNoYW5nZQ==\")"
    assert out =~ "executor_id: Base.decode64!(\"Y29kZXgtZXhlY3V0b3I=\")"
  end

  test "executor-escalate requires a decision, version, and reason" do
    for {argv, message} <- [
          {~s|--expected-version 3 --reason why|, "expects exactly one decision ID"},
          {~s|'decision:42' --reason why|, "--expected-version expects a positive integer"},
          {~s|'decision:42' --expected-version 3|, "--reason is required"}
        ] do
      {out, 64} = run_sourced_engine("cmd_executor_escalate #{argv}", [])
      assert out =~ message
    end
  end

  test "executor mutation commands dispatch through the live control path" do
    rel = fake_release()
    env = [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}]

    {answer, _code} =
      run_engine_real(
        [
          "executor-answer",
          "decision:42",
          "--expected-version",
          "3",
          "--custom-response",
          "Rebase it",
          "--rationale",
          "Known stale branch",
          "--idempotency-key",
          "exec:42:v3"
        ],
        env
      )

    {escalate, _code} =
      run_engine_real(
        ["executor-escalate", "decision:42", "--expected-version", "3", "--reason", "Irreversible"],
        env
      )

    assert answer =~ "Aiur.AgentControlCLI.executor_answer(["
    assert answer =~ "custom_response: Base.decode64!"
    assert escalate =~ "Aiur.AgentControlCLI.executor_escalate(["
  end

  test "build-orders routes its selector and JSON mode through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_build_orders 1363 --json|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.build_orders([json: true, root: Base.decode64!(\"MTM2Mw==\")])"
  end

  test "build-orders rejects multiple roots" do
    {out, 64} = run_sourced_engine(~s|cmd_build_orders 1363 1467|, [])
    assert out =~ "build-orders accepts at most one root"
  end

  test "analytics routes an explicit window through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_analytics --range full --since 2026-08-09T10:00:00Z --until 2026-08-09T11:00:00Z --build-order 1595 --json|,
        []
      )

    assert out =~ "RPC:Aiur.AgentControlCLI.analytics([range: :full, json: true"
    assert out =~ "since: Base.decode64!"
    assert out =~ "build_order: Base.decode64!"
  end

  test "github-cost routes the budget selection through the control rpc" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost --budget core --json|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "core", json: true])|
  end

  test "github-cost defaults to the GraphQL budget, which is the one that runs out" do
    {out, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost|, [])

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "graphql"])|
  end

  test "github-cost passes an output format through as an atom" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_github_cost --format records|,
        []
      )

    assert out =~ ~s|RPC:Aiur.AgentControlCLI.github_cost([budget: "graphql", format: :records])|
  end

  test "github-cost rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--budget points|, "github-cost --budget accepts graphql, core or all"},
          {~s|--budget|, "github-cost --budget requires a value"},
          {~s|--format wide|, "github-cost --format accepts auto, table or records"},
          {~s|--format|, "github-cost --format requires a value"},
          {~s|--unknown|, "github-cost received an unknown option"},
          {~s|extra|, "github-cost does not accept positional arguments"}
        ] do
      {out, 64} = run_sourced_engine("cmd_github_cost #{argv}", [])
      assert out =~ message
    end
  end

  test "analytics rejects malformed launcher arguments before an RPC" do
    for {argv, message} <- [
          {~s|--range week|, "analytics --range accepts run or full"},
          {~s|--build-order not-a-ticket|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--build-order ''|, "analytics --build-order expects a numeric ticket ID"},
          {~s|--since|, "analytics --since requires a value"},
          {~s|--unknown|, "analytics received an unknown option"}
        ] do
      {out, 64} = run_sourced_engine("cmd_analytics #{argv}", [])
      assert out =~ message
    end
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

  test "control rpc reports timeouts and missing exit markers instead of silently succeeding" do
    base = """
    resolve_release() { release_bin="/bin/true"; release_dir="/tmp"; vsn_dir="/tmp"; RELEASE_NODE="aiur-test@127.0.0.1"; }
    prepare_distribution() { :; }
    resolve_control_identity_from_records() { :; }
    probe_node_liveness() { printf up; }
    """

    timeout_script =
      base <>
        """
        run_release_rpc_with_timeout() {
          AIUR_CONTROL_RPC_OUTPUT=''
          AIUR_CONTROL_RPC_TIMED_OUT=1
          return 124
        }
        code=0
        run_control_rpc "Aiur.AgentControlCLI.resume([\"44\"])" || code=$?
        echo "CODE=$code"
        """

    {timeout_output, 0} = run_sourced_engine(timeout_script, [])
    assert timeout_output =~ "control rpc to aiur-test@127.0.0.1 timed out after 10s; outcome is unknown"
    refute timeout_output =~ "scheduler-saturated"
    refute timeout_output =~ "aiurdev stop"
    assert timeout_output =~ "CODE=124"

    missing_marker_script =
      base <>
        """
        run_release_rpc_with_timeout() {
          AIUR_CONTROL_RPC_OUTPUT=''
          AIUR_CONTROL_RPC_TIMED_OUT=0
          return 0
        }
        code=0
        run_control_rpc "Aiur.AgentControlCLI.resume([\"44\"])" || code=$?
        echo "CODE=$code"
        """

    {missing_marker_output, 0} = run_sourced_engine(missing_marker_script, [])
    assert missing_marker_output =~ "returned no exit marker; command output may be incomplete"
    assert missing_marker_output =~ "CODE=1"
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

  test "executor-wait dispatches a bounded RPC and validates timeout usage" do
    {out, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "TIMEOUT:$AIUR_CONTROL_RPC_TIMEOUT_SECONDS"; echo "RPC:$1"; }
cmd_executor_wait --timeout 2 --json|,
        []
      )

    assert out =~ "TIMEOUT:12"
    assert out =~ "Aiur.AgentControlCLI.executor_wait(timeout_ms: 2000, json: true)"

    {bad, 64} = run_sourced_engine("cmd_executor_wait --timeout nope", [])
    assert bad =~ "executor-wait --timeout expects a positive integer"
  end

  test "the takeover commands pass an explicit consumer id and nothing else" do
    {wait, 0} =
      run_sourced_engine(
        ~s|run_control_rpc() { echo "RPC:$1"; }
cmd_executor_wait --timeout 2 --as agent-b|,
        []
      )

    assert wait =~ ~s|executor_wait(timeout_ms: 2000, json: false, as: "agent-b")|

    {claim, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_claim --as agent-a|, [])
    assert claim =~ ~s|executor_claim([as: "agent-a"])|

    {release, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_release|, [])
    assert release =~ "executor_release([])"

    {revoke, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_revoke agent-a|, [])
    assert revoke =~ ~s|executor_revoke("agent-a")|

    {roster, 0} = run_sourced_engine(~s|run_control_rpc() { echo "RPC:$1"; }\ncmd_executor_roster --json|, [])
    assert roster =~ "executor_roster(json: true)"

    # A revoke must name the owner: the operator decides, so there is no
    # "revoke whoever holds it" form.
    {missing, 64} = run_sourced_engine("cmd_executor_revoke", [])
    assert missing =~ "executor-revoke requires the current owner's consumer id"

    {bad_id, 64} = run_sourced_engine("cmd_executor_claim --as 'not a/id'", [])
    assert bad_id =~ "executor-claim --as expects"
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

  test "ask boots distribution-free without requiring a running node" do
    rel = fake_release()
    state = Path.join(System.tmp_dir!(), "aiur-st-#{System.unique_integer([:positive])}")

    {out, _} = run_engine(["ask", "Enable CI readiness", "--blocking"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", state}])

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

  test "reset-budget --all exits 64 with guidance instead of silently no-opping" do
    # #1453 review P2d: `parse_issue_targets` accepts `--all` (empty targets),
    # and the original cmd_reset_budget proceeded to reset_budget([]) → exit 0
    # no-op. The command must reject --all loudly so an operator never believes
    # the whole board was reset.
    rel = fake_release()
    {out, code} = run_engine(["reset-budget", "--all"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert code == 64
    assert out =~ "reset-budget does not accept --all"
    assert out =~ "name ticket IDs explicitly"
  end

  test "reset-budget with non-numeric targets exits 64" do
    rel = fake_release()
    {out, code} = run_engine(["reset-budget", "not-an-id"], [{"AIUR_RELEASE_DIR", rel}, {"AIUR_BG_STATE_DIR", tmp_state()}])
    assert code == 64
    assert out =~ "reset-budget expects issue IDs"
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
    assert out =~ "aiur control plane at aiur-test@127.0.0.1 was still booting"
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

  # A daemon that is merely slow used to be reported exactly like a crashed
  # one -- with an empty capture, because there was no failure to print. That
  # sent debugging after a broken release instead of a short timeout.
  test "startup wait distinguishes a still-booting control plane from a crash" do
    tmux = fake_tmux_script("exit 0")
    capture = Path.join(System.tmp_dir!(), "aiur-startup-#{System.unique_integer([:positive])}")
    File.write!(capture, "")
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
        {"AIUR_NODE_GRACE_TICKS", "2"}
      ])

    assert out =~ "CODE=1"
    assert out =~ "was still booting"
    assert out =~ "the BEAM is alive but not yet answering"
    assert out =~ "AIUR_NODE_GRACE_TICKS"
    refute out =~ "did not become ready"
  end

  # The 10s budget this replaced was short enough that a healthy daemon lost
  # the race on a cold boot, so guard the floor rather than the exact value.
  test "startup wait keeps a generous default control-plane budget" do
    source = File.read!(Path.join(__DIR__, "../../packaging/npm/aiur-cli/libexec/aiur-engine.sh"))
    [_, ticks] = Regex.run(~r/AIUR_NODE_GRACE_TICKS:-(\d+)/, source)
    assert String.to_integer(ticks) >= 600
  end

  test "background startup failure cleans generated tempfiles and reaps session" do
    rel = fake_release()
    state = tmp_state()
    tmp = Path.join(System.tmp_dir!(), "aiur-bg-fail-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    tmux_state = Path.join(tmp, "tmux-session")
    dump = Path.join(tmp, "erl_crash.dump")
    ledger = Path.join(tmp, "alerts.ndjson")
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
    probe_control_liveness() {
      printf '%s\n' "$LEDGER" > "$AIUR_ALERT_LEDGER_PATH_FILE"
      printf '=erl_crash_dump:0.5\nSlogan: startup exploded\n=end\n' > "$ERL_CRASH_DUMP"
      printf down
    }
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    kill_beams_matching() { echo "KILL_BEAM:$*" >> "$EVENTS"; }
    expected_session="$TMP_ROOT/aiur-$$-sessions"
    expected_agents="$TMP_ROOT/aiur-$$-agents"
    expected_workspace_root="$TMP_ROOT/aiur-$$-workspace-root"
    expected_alert_ledger="$TMP_ROOT/aiur-$$-alert-ledger"
    expected_dump_baseline="$TMP_ROOT/aiur-$$-crash-dump-baseline"
    set +e
    ( run_session background )
    code=$?
    set -e
    echo "CODE=$code"
    for path in "$TMP_ROOT/argv" "$TMP_ROOT/startup" "$TMP_ROOT/launcher" "$expected_session" "$expected_agents" "$expected_workspace_root" "$expected_alert_ledger" "$expected_dump_baseline"; do
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
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER", ledger},
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

    [alert] = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert alert["topic"] == "system.beam.crash_dump"
    assert alert["slogan"] == "startup exploded"
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
    assert out =~ ~r/aiur control plane at aiur-enginetest-\d+@127\.0\.0\.1 was still booting/
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

  test "crash recording emits a bounded needs-attention alert for a completed dump" do
    root = Path.join(System.tmp_dir!(), "aiur-crash-alert-#{System.unique_integer([:positive])}")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    marker = Path.join(root, "last-crash")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    slogan = ~s(Failed to read from erl_child_setup: 104 "quoted" \\ #{String.duplicate("x", 700)})
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: #{slogan}\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "$RUN_LOG_DIR" "$CRASH_MARKER" "$LEDGER_PATH_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"CRASH_MARKER", marker},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    [alert] =
      ledger
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert alert["event"] == "alert"
    assert alert["agent"] == "system"
    assert alert["topic"] == "system.beam.crash_dump"
    assert alert["needs_attention"] == true
    assert alert["severity"] == "warning"
    assert alert["dump_path"] == dump
    assert alert["message"] =~ "Failed to read from erl_child_setup: 104"
    assert alert["slogan"] =~ ~s("quoted" \\)
    assert byte_size(alert["slogan"]) <= 512
    assert Enum.any?(Aiur.AlertFeed.list(ledger_paths: [ledger]), &(&1["topic"] == "system.beam.crash_dump"))
    assert File.read!(Path.join(run_log_dir, "log/aiur.crash")) =~ "crash_dump_slogan:"
  end

  test "crash recording does not alert for an incomplete dump" do
    root = Path.join(System.tmp_dir!(), "aiur-incomplete-dump-#{System.unique_integer([:positive])}")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: still being written\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "$RUN_LOG_DIR" "" "$LEDGER_PATH_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    refute File.exists?(ledger)
  end

  test "crash recording does not alert when the configured dump is missing" do
    root = Path.join(System.tmp_dir!(), "aiur-missing-dump-#{System.unique_integer([:positive])}")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|record_beam_crash "aiur-test@127.0.0.1" "" "" "$LEDGER_PATH_FILE"|,
               [
                 {"ERL_CRASH_DUMP", Path.join(root, "missing.dump")},
                 {"LEDGER_PATH_FILE", ledger_path_file}
               ]
             )

    refute File.exists?(ledger)
  end

  test "crash recording ignores a completed dump unchanged since launch" do
    root = Path.join(System.tmp_dir!(), "aiur-stale-dump-#{System.unique_integer([:positive])}")
    run_log_dir = Path.join(root, "run")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    baseline_file = Path.join(root, "dump-baseline")
    File.mkdir_p!(root)
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: stale evidence\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {_out, 0} =
             run_sourced_engine(
               ~S|crash_dump_identity "$ERL_CRASH_DUMP" >"$BASELINE_FILE"; record_beam_crash test "$RUN_LOG_DIR" "" "$LEDGER_PATH_FILE" "$BASELINE_FILE"|,
               [
                 {"RUN_LOG_DIR", run_log_dir},
                 {"ERL_CRASH_DUMP", dump},
                 {"LEDGER_PATH_FILE", ledger_path_file},
                 {"BASELINE_FILE", baseline_file}
               ]
             )

    refute File.exists?(ledger)
    refute File.read!(Path.join(run_log_dir, "log/aiur.crash")) =~ "crash_dump_slogan:"
  end

  test "watchdog still reaps when the alert ledger cannot be written" do
    root = Path.join(System.tmp_dir!(), "aiur-alert-failure-#{System.unique_integer([:positive])}")
    events = Path.join(root, "events")
    dump = Path.join(root, "erl_crash.dump")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    File.mkdir_p!(root)
    File.write!(events, "")
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: write failure\n=end\n")
    File.write!(ledger_path_file, root)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    reap_workspace_cwd_from_file() { echo "SWEEP:$*" >> "$EVENTS"; }
    pattern="aiur-watchdog-${$}-absent"
    pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1 test "$RUN_LOG_DIR" "" "$CRASH_MARKER" "" "$LEDGER_PATH_FILE" "")"
    for _ in $(seq 1 20); do
      grep -q '^SWEEP:' "$EVENTS" && break
      sleep 0.05
    done
    kill "$pid" 2>/dev/null || true
    cat "$EVENTS"
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"EVENTS", events},
        {"RUN_LOG_DIR", Path.join(root, "run")},
        {"CRASH_MARKER", Path.join(root, "marker")},
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER_PATH_FILE", ledger_path_file}
      ])

    assert out =~ "REAP:sock pidfile"
    assert out =~ "SWEEP:"
  end

  test "foreground watchdog alerts for a byte-identical replacement and removes handoffs" do
    root = Path.join(System.tmp_dir!(), "aiur-foreground-crash-#{System.unique_integer([:positive])}")
    events = Path.join(root, "events")
    dump = Path.join(root, "erl_crash.dump")
    ledger = Path.join(root, "aiur.alerts.ndjson")
    ledger_path_file = Path.join(root, "alert-ledger-path")
    baseline_file = Path.join(root, "dump-baseline")
    File.mkdir_p!(root)
    File.write!(events, "")
    File.write!(dump, "=erl_crash_dump:0.5\nSlogan: recurring crash\n=end\n")
    File.write!(ledger_path_file, ledger)
    on_exit(fn -> File.rm_rf!(root) end)

    script = """
    reap_aiur_agents() { echo "REAP:$*" >> "$EVENTS"; }
    reap_workspace_cwd_from_file() { echo "SWEEP:$*" >> "$EVENTS"; }
    crash_dump_identity "$ERL_CRASH_DUMP" > "$BASELINE_FILE"
    cp "$ERL_CRASH_DUMP" "$ERL_CRASH_DUMP.replacement"
    mv "$ERL_CRASH_DUMP.replacement" "$ERL_CRASH_DUMP"
    pattern="aiur-watchdog-${$}-absent"
    pid="$(start_beam_death_watchdog "$pattern" sock pidfile 0.05 1 foreground-node "" "" "" "" "$LEDGER_PATH_FILE" "$BASELINE_FILE")"
    for _ in $(seq 1 20); do
      [ -s "$LEDGER" ] && [ ! -e "$LEDGER_PATH_FILE" ] && [ ! -e "$BASELINE_FILE" ] && break
      sleep 0.05
    done
    kill "$pid" 2>/dev/null || true
    cat "$EVENTS"
    [ -s "$LEDGER" ] && echo ALERTED
    [ ! -e "$LEDGER_PATH_FILE" ] && echo LEDGER_HANDOFF_REMOVED
    [ ! -e "$BASELINE_FILE" ] && echo BASELINE_REMOVED
    """

    {out, 0} =
      run_sourced_engine(script, [
        {"EVENTS", events},
        {"ERL_CRASH_DUMP", dump},
        {"LEDGER", ledger},
        {"LEDGER_PATH_FILE", ledger_path_file},
        {"BASELINE_FILE", baseline_file}
      ])

    assert out =~ "REAP:sock pidfile"
    assert out =~ "ALERTED"
    assert out =~ "LEDGER_HANDOFF_REMOVED"
    assert out =~ "BASELINE_REMOVED"
    [alert] = ledger |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert alert["slogan"] == "recurring crash"
  end

  test "background run arms the detached BEAM watchdog before success" do
    rel = fake_release()
    state = tmp_state()
    logs = Path.join(state, "logs")
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          printf '%s\n' '__AIUR_CONFIG_PATH__:/tmp/project config/.aiur/config' >> "#{logs}/log/boot.out.log"
          touch "#{tmux_state}"
          exit 0
          ;;
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
    probe_dashboard_status() { printf 'Dashboard: http://127.0.0.1:4567 (bind host=127.0.0.1, port=4567)'; }
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
        {"AIUR_LOGS_ROOT", logs},
        {"AIUR_NODE_GRACE_TICKS", "2"},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "aiur started in the background"

    assert out =~
             ~r/Config: \/tmp\/project config\/\.aiur\/config\nDashboard: http:\/\/127\.0\.0\.1:4567.*\naiur started in the background/s

    events_log = File.read!(events)
    assert events_log =~ "PROBE\nWATCHDOG:-name aiur-"

    assert events_log =~
             ~r/ 1 1 aiur-\S+ \S+ \S+\.stopping \S+\.last-crash \S+-workspace-root \S+-alert-ledger \S+-crash-dump-baseline\n/

    assert events_log =~ "DISOWN:424242"
  end

  test "background launch with --no-dashboard in either-order form reports explicit suppression" do
    rel = fake_release()
    state = tmp_state()
    logs = Path.join(state, "logs")
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")

    tmux =
      fake_tmux_script("""
      case " $* " in
        *" new-session "*)
          printf '%s\n' '__AIUR_CONFIG_PATH__:/tmp/project config/.aiur/config' >> "#{logs}/log/boot.out.log"
          touch "#{tmux_state}"
          exit 0
          ;;
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
    probe_dashboard_status() { :; }
    start_beam_death_watchdog() { printf '424242\n'; }
    disown() { :; }
    aiur_engine_main --no-dashboard --bg
    """

    path = "#{Path.dirname(tmux)}:#{System.get_env("PATH")}"

    {out, 0} =
      run_sourced_engine(script, [
        {"AIUR_RELEASE_DIR", rel},
        {"AIUR_BG_STATE_DIR", state},
        {"AIUR_LOGS_ROOT", logs},
        {"PATH", path}
      ])

    assert out =~
             ~r/Config: \/tmp\/project config\/\.aiur\/config\nDashboard disabled by --no-dashboard\.\naiur started in the background/s

    refute out =~ "dashboard listener unavailable"
  end

  test "foreground attach filters tmux server-exited noise without process substitution" do
    rel = fake_release()
    state = tmp_state()
    tmux_state = Path.join(System.tmp_dir!(), "aiur-tmux-state-#{System.unique_integer([:positive])}")
    events = Path.join(System.tmp_dir!(), "aiur-events-#{System.unique_integer([:positive])}")
    dump = Path.join(System.tmp_dir!(), "aiur-dump-#{System.unique_integer([:positive])}")
    File.write!(events, "")

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
      File.rm(events)
      File.rm(dump)
    end)

    script = """
    sleep() { :; }
    probe_control_liveness() { printf up; }
    start_beam_death_watchdog() {
      printf 'WATCHDOG' >> "$EVENTS"
      printf '<%s>' "$@" >> "$EVENTS"
      printf '\n' >> "$EVENTS"
      printf '424242\\n'
    }
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
        {"ERL_CRASH_DUMP", dump},
        {"EVENTS", events},
        {"PATH", path}
      ])

    assert out =~ "CODE=7"
    assert out =~ "Dashboard disabled by --no-dashboard."
    assert out =~ "real attach error"
    refute out =~ "[server exited]"

    assert File.read!(events) =~
             ~r/WATCHDOG<-name aiur-[^>]+><[^>]+><[^>]+><1><0><aiur-[^>]+><><><><[^>]+-workspace-root><[^>]+-alert-ledger><[^>]+-crash-dump-baseline>/
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
    echo "FOUND_NOTHING=$AIUR_STOP_FOUND_NOTHING"
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
    # The flag restart reads to tell this benign nonzero apart from a real
    # stop failure; `aiur stop`'s own exit code is unchanged.
    assert out =~ "FOUND_NOTHING=1"
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
    touch -t "$OLD" "$T/aiur-4000000000-alert-ledger"
    touch -t "$OLD" "$T/aiur-4000000000-crash-dump-baseline"
    sleep 30 & LIVE=$!
    touch -t "$OLD" "$T/aiur-$LIVE-agents"
    touch -t "$OLD" "$T/aiur-$LIVE-alert-ledger"
    touch -t "$OLD" "$T/aiur-$LIVE-crash-dump-baseline"
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
    chk aiur-4000000000-alert-ledger gone
    chk aiur-4000000000-crash-dump-baseline gone
    chk "aiur-$LIVE-agents" present
    chk "aiur-$LIVE-alert-ledger" present
    chk "aiur-$LIVE-crash-dump-baseline" present
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
                   aiur-4000000000-alert-ledger aiur-4000000000-crash-dump-baseline
                   unrelated.txt) do
      assert out =~ "PASS #{name}", "missing PASS #{name} in:\n#{out}"
    end

    # The live-pid pidfile (name carries a runtime pid) was spared.
    assert out =~ ~r/PASS aiur-\d+-agents/
    assert out =~ ~r/PASS aiur-\d+-alert-ledger/
    assert out =~ ~r/PASS aiur-\d+-crash-dump-baseline/
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

  # `restart` is the one command whose whole value is an ordering: the release
  # must be refreshed while the daemon is down. These stub the stop, the build,
  # and the start so the sequence is asserted without touching a real daemon.
  defp run_restart(args, opts) do
    stop = Keyword.get(opts, :stop, "echo STOP")
    env = Keyword.get(opts, :env, [])

    # The dev shim declares AIUR_RESTART_BUILD_VERIFIES whenever it wires in a
    # rebuild, so the verifying path is the default here too; the unverified
    # branch is exercised by its own test.
    env =
      if List.keymember?(env, "AIUR_RESTART_BUILD_CMD", 0) and
           not List.keymember?(env, "AIUR_RESTART_BUILD_VERIFIES", 0) do
        [{"AIUR_RESTART_BUILD_VERIFIES", "1"} | env]
      else
        env
      end

    run_sourced_engine(
      """
      cmd_stop() { #{stop}; }
      dispatch_run() { echo "RUN: $*"; }
      cmd_restart #{args}
      """,
      env
    )
  end

  # A stand-in for the dev shim's rebuild: it stamps the release and leaves the
  # receipt the engine checks, which is what makes an "it built" claim provable
  # rather than assumed. Tests that want the unverifiable cases distort exactly
  # one of the three facts.
  defp fake_build_cmd(release_dir, opts \\ []) do
    sha = Keyword.get(opts, :sha, "cafebabe")
    stamped_sha = Keyword.get(opts, :stamped_sha, sha)
    receipt_dir = Keyword.get(opts, :receipt_dir, release_dir)
    stamp = Keyword.get(opts, :stamp, true)
    dirty = Keyword.get(opts, :dirty, "no")

    stamp_step =
      if stamp do
        ~s|printf 'repo_root=/fake\\nsource_sha=#{stamped_sha}\\ndirty=#{dirty}\\n' > "#{release_dir}/AIUR_BUILD_STAMP"; |
      else
        ""
      end

    "echo BUILD; " <>
      stamp_step <>
      ~s|printf 'release_dir=#{receipt_dir}\\nrepo_root=/fake\\nsource_sha=#{sha}\\n' > "$AIUR_RESTART_BUILD_RECEIPT"|
  end

  test "restart stops, refreshes the release, then starts detached — in that order" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    markers =
      ~r/^(STOP|BUILD|RUN: .*)$/m
      |> Regex.scan(out)
      |> Enum.map(&List.last/1)

    assert markers == ["STOP", "BUILD", "RUN: --bg"]
  end

  test "restart refuses a legacy config before stopping or rebuilding" do
    root = Path.join(System.tmp_dir!(), "aiur-restart-legacy-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".aiurconfig"), "tracker:\n  kind: memory\n")
    on_exit(fn -> File.rm_rf!(root) end)

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_REPO_ROOT", root},
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"}
        ]
      )

    assert code == 1
    assert out =~ ".aiurconfig is no longer supported"
    assert out =~ "relative prompt_file and hooks_file paths"
    refute out =~ "STOP"
    refute out =~ "BUILD"
    refute out =~ "RUN:"
  end

  test "restart confirms the release it is about to boot is the one just built" do
    # The command's whole promise is that a bounce cannot ship a stale release.
    # A rebuild that exits 0 does not establish that on its own, so the claim is
    # checked against the release on disk and reported.
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "verified release #{rel} built from abc123"
    assert out =~ "RUN: --bg"
  end

  test "restart refuses to start when the rebuild leaves no receipt" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}, {"AIUR_RELEASE_DIR", rel}]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "left no build receipt"
    assert out =~ "could not be verified"
    assert out =~ "STOPPED and was NOT restarted"
  end

  test "restart refuses to start when the rebuild targeted a different release" do
    # The defect this exists for: a globally symlinked wrapper rebuilds one
    # checkout while the daemon boots from another, and every step exits 0.
    rel = fake_release()
    other = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, receipt_dir: other)},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "targeted a different release"
    assert out =~ "rebuilt : #{other}"
    assert out =~ "booting : #{rel}"
  end

  test "restart refuses to start when the release carries no build stamp" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, stamp: false)},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "carries no build stamp"
  end

  test "restart refuses to start when the release on disk is from another commit" do
    # A concurrent build landing between the rebuild and the start would leave a
    # release nobody vouched for; the stamp catches that the boot target moved.
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123", stamped_sha: "def456")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "not built from the commit the rebuild reported"
    assert out =~ "rebuild reported : abc123"
    assert out =~ "release stamped  : def456"
  end

  test "a builder that promises no receipt is reported unverified, not stopped" do
    # AIUR_RESTART_BUILD_CMD is a documented generic hook. Holding a wrapper that
    # never promised a receipt to the receipt contract would turn an upgrade into
    # a stopped fleet; saying the guarantee did not apply is the honest answer.
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"},
          {"AIUR_RESTART_BUILD_VERIFIES", nil},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "UNVERIFIED rebuild"
    assert out =~ "RUN: --bg"
    refute out =~ "STOPPED"
  end

  test "restart refuses to start when the receipt is missing its fields" do
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", ~s|echo BUILD; printf 'repo_root=/fake\\n' > "$AIUR_RESTART_BUILD_RECEIPT"|},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 70
    refute out =~ "RUN:"
    assert out =~ "receipt is malformed"
  end

  test "an unverifiable abort names the builder it could not confirm" do
    # Without this, an inherited AIUR_RESTART_BUILD_CMD from another checkout
    # produces an identical refusal on every retry with nothing to act on.
    rel = fake_release()

    {out, 70} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BUILD"},
          {"AIUR_RESTART_BUILD_VERIFIES", "1"},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "rebuild command: echo BUILD"
  end

  test "restart declines to claim a verified boot for a release it cannot identify" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "unknown")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "source commit is"
    assert out =~ "provenance unverified"
    refute out =~ "verified release"
    assert out =~ "RUN: --bg"
  end

  test "restart says so when the release was built from a dirty tree" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel, sha: "abc123", dirty: "yes")},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert out =~ "built from abc123 with uncommitted changes"
    refute out =~ "verified release"
    assert out =~ "RUN: --bg"
  end

  test "restart forwards run flags but consumes --no-build, which skips the refresh" do
    {out, 0} =
      run_restart("--no-build --interactive --port 4099",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    refute out =~ "BUILD"
    assert out =~ "restarting on the release already on disk"
    assert out =~ "RUN: --bg --interactive --port 4099"
  end

  test "a failed refresh aborts before the start, keeps the builder's exit code, and names the state" do
    # The failure mode this command exists to prevent is a silent one: never
    # start on a stale release, and never leave the operator thinking a daemon
    # they can no longer see is still up.
    rel = fake_release()

    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "echo BOOM >&2; exit 3"},
          {"AIUR_RELEASE_DIR", rel}
        ]
      )

    assert code == 3
    refute out =~ "RUN:"
    assert out =~ "STOPPED and was NOT restarted"
    # The release survived this build, so the fast-bounce escape hatch is real.
    assert out =~ "aiur restart --no-build"
  end

  test "a failed refresh that destroyed the release does not advertise --no-build" do
    # The dev builder deletes an incomplete release. Offering `--no-build` then
    # would send the operator into a second failed cycle with the fleet down.
    {out, code} =
      run_restart("",
        env: [
          {"AIUR_RESTART_BUILD_CMD", "exit 9"},
          {"AIUR_RELEASE_DIR", Path.join(System.tmp_dir!(), "aiur-engine-no-such-release")}
        ]
      )

    assert code == 9
    assert out =~ "STOPPED and was NOT restarted"
    assert out =~ "no complete release is left on disk"
    refute out =~ "restart --no-build"
  end

  test "a start that fails after the stop still reports the stopped fleet" do
    # Every failure after the stop — not just the rebuild — must say the daemon
    # is down, or "failed to start" reads as "nothing changed".
    {out, code} =
      run_sourced_engine(
        """
        cmd_stop() { echo STOP; }
        dispatch_run() { echo "start blew up" >&2; exit 1; }
        cmd_restart
        """,
        [{"AIUR_RESTART_BUILD_CMD", nil}]
      )

    assert code == 1
    assert out =~ "STOPPED and was NOT restarted"
  end

  test "a completed restart says nothing about a stopped daemon" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    refute out =~ "STOPPED"
  end

  test "restart refuses to build or start when the stop itself failed" do
    # Only "nothing was running" is tolerable. Any other stop failure may have
    # left the BEAM alive, and rebuilding under it is the hazard the ordering
    # exists to avoid.
    {out, code} =
      run_restart("",
        stop: "echo 'stop exploded' >&2; return 7",
        env: [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    assert code == 1
    refute out =~ "BUILD"
    refute out =~ "RUN:"
    assert out =~ "stop failed (exit 7)"
  end

  test "restart with no build command wired in is a plain bounce" do
    # The installed CLI runs a pinned platform release: there is nothing to
    # build, so restart must still stop and start rather than fail.
    {out, 0} = run_restart("", env: [{"AIUR_RESTART_BUILD_CMD", nil}])

    assert out =~ "STOP"
    assert out =~ "RUN: --bg"
  end

  test "restart starts a fresh session when nothing was running" do
    rel = fake_release()

    {out, 0} =
      run_restart("",
        stop: "AIUR_STOP_FOUND_NOTHING=1; return 1",
        env: [{"AIUR_RESTART_BUILD_CMD", fake_build_cmd(rel)}, {"AIUR_RELEASE_DIR", rel}]
      )

    assert out =~ "nothing was running"
    assert out =~ "BUILD"
    assert out =~ "RUN: --bg"
  end

  test "restart refuses to rebuild or start when the stopped session still answers" do
    # cmd_stop's tmux teardown is best-effort, so a "successful" stop can leave
    # the daemon alive. Rebuilding then would rewrite the release under a live
    # BEAM, and the start would no-op into "already running" with exit 0.
    {out, code} =
      run_sourced_engine(
        """
        cmd_stop() { release_bin=/nonexistent-release-bin; echo STOP; }
        probe_control_liveness() { printf up; }
        dispatch_run() { echo "RUN: $*"; }
        cmd_restart
        """,
        [{"AIUR_RESTART_BUILD_CMD", "echo BUILD"}]
      )

    assert code == 1
    refute out =~ "BUILD"
    refute out =~ "RUN:"
    assert out =~ "still answers after the stop"
  end

  test "the restart dispatch arm drops the subcommand and forwards the rest" do
    {out, 0} =
      run_sourced_engine(
        """
        cmd_restart() { echo "RESTART: $*"; }
        aiur_engine_main restart --no-build --interactive
        """,
        []
      )

    assert out =~ "RESTART: --no-build --interactive"
  end

  test "usage advertises restart" do
    {out, 0} = run_sourced_engine("usage", [])

    assert out =~ "aiur restart"
    assert out =~ "--no-build"
  end
end
