defmodule AiurEngineRunArgvTest do
  use ExUnit.Case, async: true

  import Aiur.TestSupport.EngineCase

  test "message passes --message-id to the control RPC and validates it" do
    {out, 0} =
      run_sourced_engine(
        ~S|run_control_rpc() { echo "RPC=$1"; }; cmd_message 44 --message-id cli-1a2b continue now; | <>
          ~S|cmd_message 44 --message-id=x.y:z yes; cmd_message 44 plain text; | <>
          ~S|if (cmd_message 44 --message-id 'bad id' x) 2>/dev/null; then echo "BAD=0"; else echo "BAD=$?"; fi; | <>
          ~S|if (cmd_message 44 --message-id "" x) 2>/dev/null; then echo "EMPTY=0"; else echo "EMPTY=$?"; fi; | <>
          ~S|if (cmd_message 44 --message-id= x) 2>/dev/null; then echo "EMPTY_EQ=0"; else echo "EMPTY_EQ=$?"; fi|,
        []
      )

    encoded = Base.encode64("continue now")
    assert out =~ ~s|RPC=Aiur.AgentControlCLI.message("44", Base.decode64!("#{encoded}"), "cli-1a2b")|
    assert out =~ ~s|Base.decode64!("#{Base.encode64("yes")}"), "x.y:z")|
    assert out =~ ~s|RPC=Aiur.AgentControlCLI.message("44", Base.decode64!("#{Base.encode64("plain text")}"))|
    assert out =~ "BAD=64"
    # An empty id is an error, never a silent fallback to a plain send.
    assert out =~ "EMPTY=64"
    assert out =~ "EMPTY_EQ=64"
    refute out =~ ~s|Base.decode64!("#{Base.encode64("x")}"))|
  end

  test "an incomplete dev release returns the retryable control code" do
    rel = fake_release()
    state = tmp_state()
    signal = Aiur.TestSupport.tmp_root!("aiur-control-retry")
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
    signal = Aiur.TestSupport.tmp_root!("aiur-control-retry")
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

  test "dashboard defaults to loopback even with Tailscale and dashboard credentials" do
    bin = Aiur.TestSupport.tmp_root!("aiur-dashboard-tailscale")
    File.mkdir_p!(bin)
    tailscale = Path.join(bin, "tailscale")
    File.write!(tailscale, "#!/bin/sh\nprintf '100.64.0.42\\n'\n")
    File.chmod!(tailscale, 0o755)
    on_exit(fn -> File.rm_rf!(bin) end)

    {host, 0} =
      run_sourced_engine("default_dashboard_host", [
        {"PATH", "#{bin}:#{System.get_env("PATH")}"},
        {"AIUR_DASHBOARD_USERNAME", "tester"},
        {"AIUR_DASHBOARD_PASSWORD", "test-password"},
        {"AIUR_DEFAULT_DASHBOARD_HOST", nil}
      ])

    assert host == "127.0.0.1"

    {override_host, 0} = run_sourced_engine("default_dashboard_host", [{"AIUR_DEFAULT_DASHBOARD_HOST", "0.0.0.0"}])
    assert override_host == "0.0.0.0"
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
    capture = Aiur.TestSupport.tmp_root!("aiur config capture")
    config = "/tmp/operator config/.aiur/config"
    File.write!(capture, "booting\n__AIUR_CONFIG_PATH__:#{config}\nready\n")
    on_exit(fn -> File.rm(capture) end)

    {out, 0} = run_sourced_engine(~s(print_config_status "#{capture}"), [])

    assert out == "Config: #{config}\n"
  end

  test "config startup status makes a missing selection marker visible" do
    capture = Aiur.TestSupport.tmp_root!("aiur-empty-capture")
    File.write!(capture, "booting\n")
    on_exit(fn -> File.rm(capture) end)

    {out, 0} = run_sourced_engine(~s(print_config_status "#{capture}"), [])

    assert out =~ "selected config path unavailable"
    assert out =~ "captured startup output"
    refute out =~ capture
  end

  test "control readiness waits for full application startup before dashboard reporting" do
    engine = Aiur.EngineSource.text()

    assert engine =~ "Application.started_applications()"
    assert engine =~ "app == :aiur"
    assert engine =~ ~r/write_aiur_instance_record.*print_config_status.*print_dashboard_status/s
    assert engine =~ ~r/if ! wait_for_session_startup.*then\n\s+print_config_status/s
  end

  test "--version is distribution-free so it never collides with a running node" do
    rel = fake_release()
    state = Aiur.TestSupport.tmp_root!("aiur-st")
    elixir = Path.join([rel, "releases", "0.1.1", "elixir"])
    cli_version = cli_package() |> File.read!() |> Jason.decode!() |> Map.fetch!("version")

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

  @tag skip: Aiur.TestSupport.pgrep_skip_reason()
  test "kill_beams_matching reaps a node-name holder from any release dir" do
    # A unified node name means an orphaned BEAM from a different release dir
    # still blocks a launch; the reaper must match by `-name`, not release path.
    marker = "-name aiur-killtest-#{System.unique_integer([:positive])}@127.0.0.1"
    on_exit(fn -> System.cmd("pkill", ["-f", marker], stderr_to_stdout: true) end)

    # Run from a file so the marker isn't in the launching shell's own argv
    # (which `pgrep -f` would otherwise match and reap).
    script = """
    source #{engine()}
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

    path = Aiur.TestSupport.tmp_root!("aiur-reap") <> ".sh"
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    {out, _} = System.cmd("bash", [path], stderr_to_stdout: true)
    refute out =~ "PGREP_ERROR"
    refute out =~ "SETUP_FAILED"
    assert out =~ "REAPED"
  end

  test "workspace cwd sweep reaps only descendants of a non-shallow root" do
    if File.dir?("/proc") do
      root = Aiur.TestSupport.tmp_root!("aiur-cwd-reap")
      inside = Path.join(root, "repo/468")
      outside = Aiur.TestSupport.tmp_root!("aiur-cwd-spared")
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

  test "canonical_workspace_root expands a leading tilde" do
    home = Aiur.TestSupport.tmp_root!("aiur-tilde-canon")
    File.mkdir_p!(home)

    on_exit(fn -> File.rm_rf(home) end)

    {out, 0} =
      run_sourced_engine(
        """
        printf '%s\\n' "$(canonical_workspace_root '~/rel/path')"
        printf '%s\\n' "$(canonical_workspace_root '~')"
        printf '%s\\n' "$(canonical_workspace_root '/abs/path')"
        """,
        [{"HOME", home}]
      )

    lines = out |> String.split("\n", trim: true)
    assert lines == [Path.join(home, "rel/path"), home, "/abs/path"]
  end

  test "workspace cwd sweep reaps a ~-rooted workspace process (config root handed off verbatim)" do
    # `Config.workspace_root()` is handed off to the launcher verbatim, so a config
    # such as `workspace.root: ~/code/aiur-workspaces` reaches the cwd sweep as a
    # literal `~...` path. The sweep must expand it or it matches no /proc cwd and
    # silently reaps nothing — the exact gap that let stop orphan workspace-rooted
    # agents. `run_sourced_engine` overrides HOME so `~` resolves inside the test.
    if File.dir?("/proc") do
      home = Aiur.TestSupport.tmp_root!("aiur-tilde-home")
      root = Path.join(home, "code/aiur-workspaces")
      inside = Path.join(root, "repo/468")
      outside = Aiur.TestSupport.tmp_root!("aiur-tilde-spared")
      File.mkdir_p!(inside)
      File.mkdir_p!(outside)

      inside_pid = spawn_sleeper(inside)
      outside_pid = spawn_sleeper(outside)

      on_exit(fn ->
        kill_pid(inside_pid)
        kill_pid(outside_pid)
        File.rm_rf(home)
        File.rm_rf(outside)
      end)

      {out, 0} =
        run_sourced_engine(
          """
          AIUR_WORKSPACE_REAP_SWEEPS=2 reap_workspace_cwd_agents '~/code/aiur-workspaces'
          """,
          [{"HOME", home}]
        )

      assert out == ""
      assert wait_dead(inside_pid), "expected the ~-rooted workspace process to be reaped"
      assert os_pid_alive?(outside_pid), "expected the out-of-root process to survive"
    end
  end

  test "workspace root handoff comes from the instance record" do
    script = """
    aiur_instance_record_path() { printf '%s' "$RECORD"; }
    workspace_root_file_from_instance_record
    """

    record = Aiur.TestSupport.tmp_root!("aiur-workspace-record")
    root_file = Aiur.TestSupport.tmp_root!("aiur-workspace-root")

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
end
